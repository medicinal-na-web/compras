// Workflow n8n "Compras - Envio de e-mails aos fornecedores" — fonte para o Workflow SDK.
// Lê a fila compras_email_fila() (status pendente), envia pelo SMTP Medicinal (web.token) e grava
// compras_email_resultado(id, ok, erro). Criado INATIVO: só ligar o agendamento com o OK do Ricardo.
import { workflow, node, trigger, expr } from '@n8n/workflow-sdk';

const SUPABASE = { supabaseApi: { id: 'dpdlP9IgPpV6g6yt', name: 'Supabase FormulaCerta' } };
const SMTP = { smtp: { id: 'bjf4og3AF6C9fP7l', name: 'SMTP Medicinal (web.token)' } };
const RPC = 'https://mwhlnlqxtudcgbggkqud.supabase.co/rest/v1/rpc/';

const inicio = trigger({ type: 'n8n-nodes-base.manualTrigger', version: 1, config: { name: 'Início manual' } });
const agenda = trigger({
  type: 'n8n-nodes-base.scheduleTrigger', version: 1.3,
  config: { name: 'A cada 10 minutos', parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 10 }] } } },
});

const fila = node({
  type: 'n8n-nodes-base.httpRequest', version: 4.3,
  config: {
    name: 'Fila de e-mails',
    parameters: {
      method: 'POST', url: RPC + 'compras_email_fila',
      authentication: 'predefinedCredentialType', nodeCredentialType: 'supabaseApi',
      sendBody: true, contentType: 'json', specifyBody: 'json', jsonBody: '{"p_limite": 50}',
      options: {},
    },
    credentials: SUPABASE,
  },
});

const prepara = node({
  type: 'n8n-nodes-base.code', version: 2,
  config: { name: 'Prepara e-mail', parameters: { mode: 'runOnceForAllItems', jsCode:
`return $input.all().map(i => i.json).filter(e => e && e.id && Array.isArray(e.para) && e.para.length)
  .map(e => ({ json: { id: e.id, para: e.para.join(', '), assunto: e.assunto, corpo: e.corpo } }));` } },
});

const envia = node({
  type: 'n8n-nodes-base.emailSend', version: 2.1,
  config: {
    name: 'Envia e-mail', onError: 'continueRegularOutput',
    parameters: {
      fromEmail: 'web.token@medicinalnaweb.com.br',
      toEmail: expr('{{ $json.para }}'),
      subject: expr('{{ $json.assunto }}'),
      emailFormat: 'text',
      text: expr('{{ $json.corpo }}'),
      options: { appendAttribution: false },
    },
    credentials: SMTP,
  },
});

const resultado = node({
  type: 'n8n-nodes-base.code', version: 2,
  config: { name: 'Monta resultado', parameters: { mode: 'runOnceForEachItem', jsCode:
`const r = $json, id = $('Prepara e-mail').item.json.id;
const erro = r.error ? (r.error.message || JSON.stringify(r.error)) : null;
return { json: { id, body: { p_id: id, p_ok: !erro, p_erro: erro } } };` } },
});

const grava = node({
  type: 'n8n-nodes-base.httpRequest', version: 4.3,
  config: {
    name: 'Grava resultado',
    parameters: {
      method: 'POST', url: RPC + 'compras_email_resultado',
      authentication: 'predefinedCredentialType', nodeCredentialType: 'supabaseApi',
      sendBody: true, contentType: 'json', specifyBody: 'json',
      jsonBody: expr('{{ JSON.stringify($json.body) }}'),
      options: {},
    },
    credentials: SUPABASE,
  },
});

export default workflow('compras-envio-emails', 'Compras - Envio de e-mails aos fornecedores')
  .add(inicio).to(fila).to(prepara).to(envia).to(resultado).to(grava)
  .add(agenda).to(fila);
