-- compras_fornecedor: cadastro de fornecedores (FC02000) com contato, telefone e e-mails.
-- Banco: Firebird (Fórmula Certa), réplica. Os textos vêm com bytes nulos no fim: o n8n tira antes de enviar.
-- EMAIL e EMAIL2 às vezes guardam telefone ou anotação; a carga (compras_sync_cadastro_fornecedor) só aproveita e-mails válidos.
SELECT F.FORNECID, TRIM(F.NRCNPJ) AS NRCNPJ, TRIM(F.FANTA) AS FANTA, TRIM(F.RAZAO) AS RAZAO,
       TRIM(F.CTATO) AS CTATO, TRIM(F.EMAIL) AS EMAIL, TRIM(F.EMAIL2) AS EMAIL2,
       TRIM(F.NRDDD) AS NRDDD, TRIM(F.NRTEL) AS NRTEL
FROM FC02000 F
