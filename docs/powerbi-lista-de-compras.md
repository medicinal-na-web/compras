# Engenharia reversa: LISTADECOMPRAS.V7.pbix

Inventário do relatório Power BI que gera a lista de compras a partir do Fórmula Certa.
Serve de especificação para replicar o painel fora do Power BI.

## 1. Origem dos dados

O `.pbix` **não acessa o banco do Fórmula Certa diretamente**. Todas as tabelas vêm de um
**Dataflow do Power BI** (workspace `415849bf-7d91-4106-a252-ea8d013a8b17`,
dataflow `d4798ed0-f187-40fa-8b4c-d826a1421870`). O SQL contra o banco está no dataflow,
que precisa ser exportado à parte (Power BI Service → dataflow → *Exportar .json*).

| Entidade do dataflow | Conteúdo | Linhas no snapshot |
|---|---|---|
| `FC03000` | Cadastro de produtos | 5.002 (após filtro) |
| `FC03140` | Lotes / estoque por filial | 340.963 |
| `Dataset_Compras_FC03140` | Estoque agregado por produto: `ESTOQUEFILIAL1`, `ESTOQUEFILIAL2` | 10.241 |
| `DataSet_Compras_12110_18100` | Consumo agregado por produto (FC12110 + FC18100): soma de custo, físico e frequência em 30 e 90 dias, por filial (`…FP`) e consolidado | 2.723 |

### Transformação de `FC03000` (Power Query)

1. Remove colunas não usadas.
2. Filtra `GRUPO = "M"` e `SETOR = "001"`.
3. Cria `IndicaControlado = 0` se `PORTA` vazio (ou dois espaços), senão `1`.
4. Left join por `CDPRO` com `Dataset_Compras_FC03140`, trazendo `ESTOQUEFILIAL1` e `ESTOQUEFILIAL2`.
5. Left join por `CDPRO` com `DataSet_Compras_12110_18100`, trazendo `CONSOLIDADO{CUSTO,FREQUENCIA,FISICO}{30D,90D}`.
6. Substitui `null` por `0` nessas colunas.

Relacionamento do modelo: `FC03140[CDPRO]` (N) → `FC03000[CDPRO]` (1), filtro em uma direção.

## 2. Páginas

| Página | Visível | Conteúdo |
|---|---|---|
| **PainelSintetico** | sim | Matriz por produto (detalhada abaixo) |
| Página 1 | oculta | Anotações: regras das listas e a matriz de combinação de curvas |
| ORIETANÇÃO DE AJUSTYE | oculta | Nota de 15/12/2025: "Para compras de Dezembro, reduzimos de 45 para 30 o DiaConsumoFilial2 — sugerido retornar para 45 assim que possível" |

### Matriz da PainelSintetico

Linha: `FC03000[CDPRO]` ("Cod"). Ordenada por `IndicaCompra` decrescente (os "Comprar" primeiro).

| Coluna | Origem |
|---|---|
| Descrição | `FC03000[DESCR]` |
| ESTOQUEFILIAL1 | `FC03000[ESTOQUEFILIAL1]` |
| ESTOQUEFILIAL2 | `FC03000[ESTOQUEFILIAL2]` |
| CONSOLIDADOFISICO30D | `FC03000[CONSOLIDADOFISICO30D]` |
| PRCOMN | `FC03000[PRCOMN]` (preço de compra) |
| QuantidadeCompra | medida |
| DiasConsumoGeral | medida |
| IndicaCompra | medida |

O visual tem um filtro em `FC03140[DTENT]` sem condição definida. Como o relacionamento
filtra só de `FC03000` para `FC03140`, esse filtro também não afetaria a matriz.

## 3. Regra de negócio (medidas usadas pela matriz)

Universo: produtos de `FC03000` já filtrados (grupo M, setor 001).

### 3.1 Curvas ABC (três dimensões)

Para cada dimensão — **Financeiro** (`CONSOLIDADOCUSTO90D`), **Físico** (`CONSOLIDADOFISICO90D`)
e **Frequência** (`CONSOLIDADOFREQUENCIA90D`):

1. `participação = valor do produto / soma de todos os produtos`
2. `rank` = posição decrescente pela participação (`RANKX`: empates recebem o mesmo rank)
3. `acumulado` = soma das participações de todos os produtos com `rank <= rank do produto`
4. Nota: `acumulado < 0,80` → **3 (curva A)**; `< 0,95` → **2 (B)**; `<= 1,1` → **1 (C)**

Produtos sem consumo empatam no último rank, ficam com acumulado = 1 e caem na curva C.

### 3.2 Lista geral (`ListaClassificaGeral1`)

`nota = financeiro + físico + frequência` (de 3 a 9):

| Nota | Lista |
|---|---|
| 8–9 | LISTA 1 |
| 6–7 | LISTA 2 |
| 5 | LISTA 3 |
| 4 | LISTA 4 |
| 3 (C/C/C) | LISTA 5 |

> A versão anterior (`ListaClassificaGeral1_bkup`, e o texto da "Página 1") usava uma matriz
> explícita de 27 combinações. Ela não está mais em uso: a soma de notas a substituiu.

### 3.3 Consumo e cobertura

- `MediaConsumoDiario = (CONSOLIDADOFISICO30D + CONSOLIDADOFISICO90D) / 120`
  (média ponderada: os últimos 30 dias contam em dobro)
- `DiasConsumoGeral = (ESTOQUEFILIAL1 × 0,6 + ESTOQUEFILIAL2) / MediaConsumoDiario`
- `DiasConsumoFilial2 = ESTOQUEFILIAL2 / MediaConsumoDiario`
- Divisão por zero devolve vazio (BLANK). No DAX, `BLANK > n` é falso e `BLANK < n` é verdadeiro.

### 3.4 Indicação de compra (`IndicaCompra`)

| Lista | Regra → "Comprar" |
|---|---|
| LISTA 5 | consumo 90d > 0 **e** DiasConsumoGeral ≤ 45 |
| LISTA 4 | DiasConsumoGeral ≤ 45 |
| LISTA 3 | DiasConsumoGeral ≤ 45 |
| LISTA 2 | DiasConsumoFilial2 ≤ 30 **e** (não controlado **ou** DiasConsumoGeral < 45) |
| LISTA 1 | mesma regra da LISTA 2 |
| sem lista | "avaliar" |

O limite de 30 dias para DiasConsumoFilial2 é o ajuste temporário de dezembro (o valor original era 45).

### 3.5 Quantidade sugerida (`QuantidadeCompra`)

Só para itens "Comprar": `necessidade = MediaConsumoDiario × 30`, arredondada **para cima**
até a próxima embalagem padrão:

`1, 5, 10, 25, 50, 100, 250, 500, 1.000, 2.500, 5.000, 10.000, 25.000, 50.000, 100.000, 150.000, 300.000`

Acima de 300.000 o resultado é 0.

`TotalComprar = PRCOMN × QuantidadeCompra` (definida no modelo, mas fora da matriz).

## 4. Medidas sem uso no painel

A tabela `MEDIDAS` tem várias medidas exploratórias que nenhum visual usa: `Estoque | Compra`,
`Estoque | Custo`, `Consumo | Aponta Vencimento`, `ACUMULATIVO`, `%RejeiçãoPorProduto`,
`MATRIX_*`, `ContaCurvaA` etc. Algumas citam tabelas que nem estão mais no modelo
(`FC12110`, `FC15110`, `Lista de Orcamentos Rejeitados`). Para replicar o painel, não precisam ser portadas.

## 5. Validação no snapshot do arquivo

Reimplementando as regras acima sobre os dados que vêm dentro do `.pbix`:

| Lista | Produtos |
|---|---|
| LISTA 1 | 86 |
| LISTA 2 | 214 |
| LISTA 3 | 180 |
| LISTA 4 | 284 |
| LISTA 5 | 4.238 |

**340 itens "Comprar"**, somando cerca de **R$ 243 mil** (`PRCOMN × QuantidadeCompra`).
Esses números precisam ser conferidos contra o Power BI (exportar a matriz para Excel e comparar).

## 6. Pendências

- [ ] Exportar o JSON do dataflow para obter o SQL contra o Fórmula Certa (tabelas FC03000, FC03140, FC12110, FC18100).
- [ ] Confirmar o significado de filial 1 × filial 2 e do peso 0,6 no estoque da filial 1.
- [ ] Decidir se o limite de 30 dias (ajuste de dezembro) volta para 45 e se deve virar parâmetro editável.
- [ ] Exportar a matriz do Power BI para validar os números da seção 5.
