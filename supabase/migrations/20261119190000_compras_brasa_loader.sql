-- Publicação do Portal de Compras no site (Brasa CMS, rota /compras): o fragmento HTML
-- (portal/app/compras.html) fica em partes base64 e o CMS lê pelo loader, como nos outros portais.
-- Conteúdo gravado por portal/publicar.py (gera o SQL de troca das partes).
create table if not exists public._brasa_parts_compras (part integer primary key, b text not null);
alter table public._brasa_parts_compras enable row level security;
revoke all on public._brasa_parts_compras from anon, authenticated;

create or replace function public.brasa_loader_compras()
returns text language sql stable security definer set search_path = public as $$
  select convert_from(decode(string_agg(b, '' order by part), 'base64'), 'UTF8') from public._brasa_parts_compras;
$$;
grant execute on function public.brasa_loader_compras() to anon, authenticated, service_role;
