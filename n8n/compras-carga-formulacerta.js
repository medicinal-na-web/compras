// Workflow n8n "Compras - Carga FórmulaCerta (réplica)" — fonte para o Workflow SDK.
// Lê a réplica Firebird (só SELECT) e grava no Supabase formulaCerta pelas funções compras_carga_*,
// em lotes de 500, fechando cada tabela com compras_carga_fechar. Um conjunto por vez, em sequência.
import { workflow, node, trigger, expr } from '@n8n/workflow-sdk';

const FIREBIRD = { firebirdWin1252Api: { id: 'KA4ckmE4aFAjOxUz', name: 'Firebird (WIN1252) Replica Producao' } };
const SUPABASE = { supabaseApi: { id: 'dpdlP9IgPpV6g6yt', name: 'Supabase FormulaCerta' } };
const RPC = 'https://mwhlnlqxtudcgbggkqud.supabase.co/rest/v1/rpc/';

const CONJUNTOS = [
  { chave: 'produto', titulo: 'produtos FC03000', fn: 'compras_carga_produto',
    sql: 'SELECT P.CDPRO, P.DESCR, P.GRUPO, P.SETOR, P.SITUA, P.UNIDA, P.PRCOM, P.PRCOMN, P.PORTA FROM FC03000 P' },
  { chave: 'estoque', titulo: 'estoque FC03140', fn: 'compras_carga_estoque',
    sql: 'SELECT CDPRO, SUM(IIF(CDFIL = 1, ESTAT, 0)) AS ESTOQUEFILIAL1, SUM(IIF(CDFIL = 2, ESTAT, 0)) AS ESTOQUEFILIAL2 FROM FC03140 GROUP BY CDPRO' },
  { chave: 'consumo', titulo: 'consumo FC12110 + FC18100', fn: 'compras_carga_consumo',
    sql: `WITH
Q1 AS (
  SELECT CDPRIN AS CDPRO,
    SUM(CASE WHEN DTENTR >= CURRENT_DATE - 30 THEN 1 ELSE 0 END) AS SomaFrequencia30D,
    SUM(CASE WHEN DTENTR >= CURRENT_DATE - 30 THEN QTREAL ELSE 0 END) AS SomaFisico30D,
    SUM(CASE WHEN DTENTR >= CURRENT_DATE - 30 THEN PRCUSTO ELSE 0 END) AS SomaCusto30D,
    SUM(CASE WHEN DTENTR >= CURRENT_DATE - 90 THEN 1 ELSE 0 END) AS SomaFrequencia90D,
    SUM(CASE WHEN DTENTR >= CURRENT_DATE - 90 THEN QTREAL ELSE 0 END) AS SomaFisico90D,
    SUM(CASE WHEN DTENTR >= CURRENT_DATE - 90 THEN PRCUSTO ELSE 0 END) AS SomaCusto90D,
    0 AS SomaFrequencia30DFP, 0 AS SomaFisico30DFP, 0 AS SomaCusto30DFP,
    0 AS SomaFrequencia90DFP, 0 AS SomaFisico90DFP, 0 AS SomaCusto90DFP
  FROM FC12110 WHERE DTENTR >= CURRENT_DATE - 90 GROUP BY CDPRIN
),
Q2 AS (
  SELECT i.CDPRO,
    0 AS SomaFrequencia30D, 0 AS SomaFisico30D, 0 AS SomaCusto30D,
    0 AS SomaFrequencia90D, 0 AS SomaFisico90D, 0 AS SomaCusto90D,
    SUM(IIF(o.DTORD >= CURRENT_DATE - 30, 1, 0)) AS SomaFrequencia30DFP,
    SUM(IIF(o.DTORD >= CURRENT_DATE - 30, i.QTREAL, 0)) AS SomaFisico30DFP,
    SUM(IIF(o.DTORD >= CURRENT_DATE - 30, i.QTREAL * p.PRCOM, 0)) AS SomaCusto30DFP,
    SUM(IIF(o.DTORD >= CURRENT_DATE - 90, 1, 0)) AS SomaFrequencia90DFP,
    SUM(IIF(o.DTORD >= CURRENT_DATE - 90, i.QTREAL, 0)) AS SomaFisico90DFP,
    SUM(IIF(o.DTORD >= CURRENT_DATE - 90, i.QTREAL * p.PRCOM, 0)) AS SomaCusto90DFP
  FROM FC18100 i JOIN FC18000 o ON o.NRORD = i.NRORD JOIN FC03000 p ON p.CDPRO = i.CDPRO
  WHERE o.DTORD >= CURRENT_DATE - 90 GROUP BY i.CDPRO
),
UNION_Q AS (SELECT * FROM Q1 UNION ALL SELECT * FROM Q2)
SELECT CDPRO,
  SUM(SomaFrequencia30D) AS SomaFrequencia30D, SUM(SomaFisico30D) AS SomaFisico30D, SUM(SomaCusto30D) AS SomaCusto30D,
  SUM(SomaFrequencia90D) AS SomaFrequencia90D, SUM(SomaFisico90D) AS SomaFisico90D, SUM(SomaCusto90D) AS SomaCusto90D,
  SUM(SomaFrequencia30DFP) AS SomaFrequencia30DFP, SUM(SomaFisico30DFP) AS SomaFisico30DFP, SUM(SomaCusto30DFP) AS SomaCusto30DFP,
  SUM(SomaFrequencia90DFP) AS SomaFrequencia90DFP, SUM(SomaFisico90DFP) AS SomaFisico90DFP, SUM(SomaCusto90DFP) AS SomaCusto90DFP,
  SUM(SomaCusto30D) + SUM(SomaCusto30DFP) AS ConsolidadoCusto30D,
  SUM(SomaFrequencia30D) + SUM(SomaFrequencia30DFP) AS ConsolidadoFrequencia30D,
  SUM(SomaFisico30D) + SUM(SomaFisico30DFP) AS ConsolidadoFisico30D,
  SUM(SomaCusto90D) + SUM(SomaCusto90DFP) AS ConsolidadoCusto90D,
  SUM(SomaFrequencia90D) + SUM(SomaFrequencia90DFP) AS ConsolidadoFrequencia90D,
  SUM(SomaFisico90D) + SUM(SomaFisico90DFP) AS ConsolidadoFisico90D
FROM UNION_Q GROUP BY CDPRO` },
  { chave: 'fornecedor', titulo: 'fornecedores FC02000', fn: 'compras_carga_fornecedor',
    sql: 'SELECT F.FORNECID, TRIM(F.NRCNPJ) AS NRCNPJ, TRIM(F.FANTA) AS FANTA, TRIM(F.RAZAO) AS RAZAO, TRIM(F.CTATO) AS CTATO, TRIM(F.EMAIL) AS EMAIL, TRIM(F.EMAIL2) AS EMAIL2, TRIM(F.NRDDD) AS NRDDD, TRIM(F.NRTEL) AS NRTEL FROM FC02000 F' },
  { chave: 'produto_fornecedor', titulo: 'fornecedor do último lote FC03140', fn: 'compras_carga_produto_fornecedor', ultimoLote: true,
    sql: "SELECT L.CDPRO, TRIM(L.CDFNR) AS CDFNR, CAST(L.DTENT AS VARCHAR(10)) AS DTENT FROM FC03140 L WHERE COALESCE(L.ORLOT, '') <> 'FORMULA PADRAO' AND L.CDFNR IS NOT NULL AND L.DTENT BETWEEN CURRENT_DATE - 1095 AND CURRENT_DATE" },
];

const http = (nome) => node({
  type: 'n8n-nodes-base.httpRequest', version: 4.3,
  config: {
    name: nome,
    parameters: {
      method: 'POST',
      url: expr('{{ "' + RPC + '" + $json.fn }}'),
      authentication: 'predefinedCredentialType', nodeCredentialType: 'supabaseApi',
      sendBody: true, contentType: 'json', specifyBody: 'json',
      jsonBody: expr('{{ JSON.stringify($json.body) }}'),
      options: { timeout: 180000, response: { response: { fullResponse: true, neverError: true } } },
    },
    credentials: SUPABASE,
  },
});

const inicio = trigger({ type: 'n8n-nodes-base.manualTrigger', version: 1, config: { name: 'Início manual' } });
const agenda = trigger({
  type: 'n8n-nodes-base.scheduleTrigger', version: 1.3,
  config: { name: 'Todo dia 05:40', parameters: { rule: { interval: [{ field: 'cronExpression', expression: '40 5 * * *' }] } } },
});
const marca = node({
  type: 'n8n-nodes-base.code', version: 2,
  config: { name: 'Marca a carga', parameters: { mode: 'runOnceForAllItems', jsCode: "return [{ json: { carga: new Date().toISOString() } }];" } },
});

let wf = workflow('compras-carga-formulacerta', 'Compras - Carga FórmulaCerta (réplica)').add(inicio).to(marca).add(agenda).to(marca);
let anterior = marca;
const fechos = [];

for (const c of CONJUNTOS) {
  const leitura = node({
    type: 'n8n-nodes-firebird-charset.firebirdWin1252', version: 1,
    config: { name: 'FC - ' + c.titulo, executeOnce: true, alwaysOutputData: true,
              parameters: { operation: 'executeQuery', query: c.sql, timeout: 600 }, credentials: FIREBIRD },
  });
  const lotes = node({
    type: 'n8n-nodes-base.code', version: 2,
    config: { name: 'Lotes - ' + c.chave, parameters: { mode: 'runOnceForAllItems', jsCode:
`const limpa = v => typeof v === 'string' ? v.replace(/\\u0000/g, '').trim() : v;
let linhas = $input.all().map(i => i.json).filter(r => r && Object.keys(r).length)
  .map(r => Object.fromEntries(Object.entries(r).map(([k, v]) => [k, limpa(v)])));
${c.ultimoLote ? `const ult = {};
for (const r of linhas) { if (!ult[r.CDPRO] || String(r.DTENT) > String(ult[r.CDPRO].DTENT)) ult[r.CDPRO] = r; }
linhas = Object.values(ult);` : ''}
const carga = $('Marca a carga').first().json.carga, out = [];
for (let i = 0; i < linhas.length; i += 500) out.push({ json: { fn: '${c.fn}', lidas: linhas.length, body: { p_linhas: linhas.slice(i, i + 500), p_carga: carga } } });
if (!out.length) out.push({ json: { fn: '${c.fn}', lidas: 0, body: { p_linhas: [], p_carga: carga } } });
return out;` } },
  });
  const grava = http('Supabase - carga ' + c.chave);
  const fecha = node({
    type: 'n8n-nodes-base.code', version: 2,
    config: { name: 'Fechamento - ' + c.chave, parameters: { mode: 'runOnceForAllItems', jsCode:
`const r = $input.all().map(i => i.json);
const erros = r.filter(x => !(x.statusCode >= 200 && x.statusCode < 300)).map(x => JSON.stringify(x.body).slice(0, 300));
const aceitas = r.reduce((s, x) => s + (Number(x.body) || 0), 0);
// com erro em algum lote, total -1 faz o fechamento recusar e não apagar nada
return [{ json: { fn: 'compras_carga_fechar', lidas: $('Lotes - ${c.chave}').first().json.lidas, lotes: r.length, erros,
  body: { p_tabela: '${c.chave}', p_carga: $('Marca a carga').first().json.carga, p_total: erros.length ? -1 : aceitas } } }];` } },
  });
  const fechou = http('Supabase - fecha ' + c.chave);
  wf = wf.add(anterior).to(leitura).to(lotes).to(grava).to(fecha).to(fechou);
  anterior = fechou;
  fechos.push(c.chave);
}

const resumo = node({
  type: 'n8n-nodes-base.code', version: 2,
  config: { name: 'Resumo da carga', parameters: { mode: 'runOnceForAllItems', jsCode:
`const chaves = ${JSON.stringify(fechos)};
return [{ json: Object.fromEntries(chaves.map(k => [k, {
  lidas: $('Fechamento - ' + k).first().json.lidas,
  erros: $('Fechamento - ' + k).first().json.erros,
  fechamento: $('Supabase - fecha ' + k).first().json.body,
}])) }];` } },
});

export default wf.add(anterior).to(resumo);
