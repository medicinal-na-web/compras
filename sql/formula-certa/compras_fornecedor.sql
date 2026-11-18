-- compras_fornecedor: cadastro de fornecedores (nome fantasia e razão social) por CNPJ.
-- Banco: Firebird (Fórmula Certa), réplica. Os campos vêm com bytes nulos no fim; a carga limpa.
SELECT F.FORNECID, TRIM(F.NRCNPJ) AS NRCNPJ, TRIM(F.RAZAO) AS RAZAO, TRIM(F.FANTA) AS FANTA
FROM FC02000 F
