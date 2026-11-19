#!/usr/bin/env python3
"""Gera o SQL que publica portal/app/compras.html em public._brasa_parts_compras.
Uso: python3 portal/publicar.py > /tmp/publica.sql  (rodar o SQL no Supabase formulaCerta).
Faz backup da versão anterior em _brasa_parts_compras_bkp_<data> antes de trocar."""
import base64, datetime, pathlib, sys
html = pathlib.Path(__file__).with_name('app').joinpath('compras.html').read_bytes()
b = base64.b64encode(html).decode()
partes = [b[i:i + 8000] for i in range(0, len(b), 8000)]
bkp = '_brasa_parts_compras_bkp_' + datetime.datetime.now().strftime('%Y%m%d%H%M')
print('begin;')
print(f'create table if not exists public.{bkp} as table public._brasa_parts_compras;')
print(f'alter table public.{bkp} enable row level security;')
print(f'revoke all on public.{bkp} from anon, authenticated;')
print('delete from public._brasa_parts_compras;')
print('insert into public._brasa_parts_compras (part, b) values')
print(',\n'.join(f"({i + 1}, '{p}')" for i, p in enumerate(partes)) + ';')
print('commit;')
print(f'-- {len(html)} bytes, {len(partes)} partes', file=sys.stderr)
