-- =========================================================
-- 012 · App LAVADERO sobre el proyecto Supabase "orbe-clientes".
-- Sigue la numeración de cancha-padel/supabase (001–011): la base es la misma.
--
-- Reutiliza sin cambios: clubs (cada lavadero es un cliente con app='lavadero'),
-- dispositivos + código de activación, operadores + PIN + sesiones_op (_op/_admin),
-- historial, pagos y todo el panel (cuota, vencimiento, bloqueo automático).
--
-- Agrega: tablas lav_* (todas con club_id → aislamiento por cliente con RLS),
-- funciones lav_* (única forma de escribir) y estadísticas del lavadero en el panel.
-- Seguro de correr dos veces.
-- =========================================================

-- ---------- catálogo del panel ----------
insert into public.apps (id, nombre, url, color) values
  ('lavadero', 'Lavadero de autos', 'https://orbepy.com/lavadero/?club={club}', '#E3B341')
  on conflict (id) do nothing;

-- La app necesita saber de qué tipo es el cliente para no abrir datos de otra app.
grant select (app) on public.clubs to authenticated;

-- ---------- tablas ----------
create table if not exists public.lav_config (
  club_id      text primary key references public.clubs(id) on delete cascade,
  telefono     text not null default '',
  direccion    text not null default '',
  msg_retira   text not null default 'Hola {cliente}! Tu {vehiculo} ({chapa}) ya está listo en {lavadero}. Podés pasar a retirarlo cuando quieras. Total: {total}. ¡Gracias!',
  msg_delivery text not null default 'Hola {cliente}! Tu {vehiculo} ({chapa}) ya está listo y te lo estamos llevando a {direccion}. Total: {total}. ¡Gracias por elegir {lavadero}!',
  logo         text,
  seq          int  not null default 0,
  actualizado  timestamptz not null default now(),
  constraint lav_config_logo check (logo is null or (logo like 'data:image/%' and length(logo) <= 400000))
);

create table if not exists public.lav_servicios (
  id      uuid primary key default gen_random_uuid(),
  club_id text not null references public.clubs(id) on delete cascade,
  nombre  text not null,
  p_auto  int  not null default 0 check (p_auto >= 0),
  p_suv   int  not null default 0 check (p_suv  >= 0),
  p_moto  int  not null default 0 check (p_moto >= 0),
  activo  boolean not null default true,
  orden   int  not null default 0,
  creado  timestamptz not null default now()
);
create index if not exists lav_servicios_club on public.lav_servicios (club_id);

create table if not exists public.lav_clientes (
  id        uuid primary key default gen_random_uuid(),
  club_id   text not null references public.clubs(id) on delete cascade,
  nombre    text not null default '',
  tel       text not null default '',
  tel_norm  text not null default '',
  direccion text not null default '',
  creado    timestamptz not null default now()
);
create index if not exists lav_clientes_club on public.lav_clientes (club_id);
create index if not exists lav_clientes_tel on public.lav_clientes (club_id, tel_norm) where tel_norm <> '';

create table if not exists public.lav_vehiculos (
  id         uuid primary key default gen_random_uuid(),
  club_id    text not null references public.clubs(id) on delete cascade,
  chapa      text not null check (chapa ~ '^[A-Z0-9]{4,10}$'),
  tipo       text not null default 'auto' check (tipo in ('auto', 'suv', 'moto')),
  marca      text not null default '',
  color      text not null default '',
  cliente_id uuid references public.lav_clientes(id) on delete set null,
  creado     timestamptz not null default now(),
  unique (club_id, chapa)
);

create table if not exists public.lav_ordenes (
  id           uuid primary key default gen_random_uuid(),
  club_id      text not null references public.clubs(id) on delete cascade,
  num          int  not null,
  vehiculo_id  uuid references public.lav_vehiculos(id) on delete set null,
  cliente_id   uuid references public.lav_clientes(id) on delete set null,
  chapa        text not null,
  tipo         text not null check (tipo in ('auto', 'suv', 'moto')),
  servicios    jsonb not null default '[]'::jsonb,     -- [{id, nombre, precio}] con el precio congelado
  total        int  not null default 0 check (total >= 0),
  entrega      text not null default 'retira' check (entrega in ('retira', 'delivery')),
  direccion    text not null default '',
  nota         text not null default '',
  estado       text not null default 'espera' check (estado in ('espera', 'lavando', 'listo', 'entregado', 'cancelado')),
  pagado       boolean not null default false,
  metodo       text check (metodo in ('efectivo', 'transferencia', 'tarjeta', 'qr')),
  pagado_ts    timestamptz,
  recibio      text not null default '',
  lavador      text not null default '',
  cobro        text not null default '',
  creado       timestamptz not null default now(),
  t_lavando    timestamptz,
  t_listo      timestamptz,
  t_entregado  timestamptz,
  avisado      boolean not null default false,
  avisado_ts   timestamptz,
  aviso_tipo   text,
  motivo       text not null default '',
  cancelado_por text not null default '',
  cancelado_ts timestamptz,
  actualizado  timestamptz not null default now(),
  unique (club_id, num)
);
create index if not exists lav_ordenes_club_creado on public.lav_ordenes (club_id, creado desc);
-- Una chapa no puede estar dos veces en el local (aunque toquen "Registrar" en dos tablets a la vez).
create unique index if not exists lav_ordenes_una_abierta on public.lav_ordenes (club_id, chapa)
  where estado in ('espera', 'lavando', 'listo');

-- ---------- seguridad: cada dispositivo ve solo su lavadero; nadie escribe directo ----------
do $$
declare t text;
begin
  foreach t in array array['lav_config', 'lav_servicios', 'lav_clientes', 'lav_vehiculos', 'lav_ordenes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists ver_club on public.%I', t);
    execute format('create policy ver_club on public.%I for select to authenticated using (public.es_miembro(club_id))', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('revoke insert, update, delete, truncate on public.%I from authenticated', t);
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- ---------- ayudantes internos ----------
-- Solo lavaderos: un código de otra app no puede tocar estas tablas.
create or replace function public._lav(p_club text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.clubs where id = p_club and app = 'lavadero') then raise exception 'APP_INCORRECTA'; end if;
end $$;

create or replace function public._lav_cfg(p_club text) returns public.lav_config
language plpgsql security definer set search_path = public as $$
declare c public.lav_config;
begin
  insert into public.lav_config (club_id) values (p_club) on conflict (club_id) do nothing;
  select * into c from public.lav_config where club_id = p_club;
  return c;
end $$;

create or replace function public._lav_chapa(t text) returns text language sql immutable as $$
  select upper(regexp_replace(coalesce(t, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

-- ---------- configuración (admin) ----------
create or replace function public.lav_inicio(p_club text, p_token uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operadores;
begin
  o := public._op(p_club, p_token);
  perform public._lav(p_club);
  perform public._lav_cfg(p_club);
end $$;

create or replace function public.lav_config_guardar(p_club text, p_token uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operadores; v_nombre text := left(trim(coalesce(p ->> 'nombre', '')), 60);
begin
  o := public._admin(p_club, p_token);
  perform public._lav(p_club);
  perform public._lav_cfg(p_club);
  if v_nombre = '' then raise exception 'FALTA_NOMBRE'; end if;
  update public.clubs set nombre = v_nombre where id = p_club;
  update public.lav_config set
    telefono     = left(trim(coalesce(p ->> 'telefono', '')), 30),
    direccion    = left(trim(coalesce(p ->> 'direccion', '')), 120),
    msg_retira   = coalesce(nullif(left(trim(coalesce(p ->> 'msg_retira', '')), 600), ''), msg_retira),
    msg_delivery = coalesce(nullif(left(trim(coalesce(p ->> 'msg_delivery', '')), 600), ''), msg_delivery),
    actualizado  = now()
  where club_id = p_club;
  perform public._log(p_club, o.nombre, 'Ajustes guardados', '');
end $$;

create or replace function public.lav_logo_guardar(p_club text, p_token uuid, p_logo text)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operadores;
begin
  o := public._admin(p_club, p_token);
  perform public._lav(p_club);
  perform public._lav_cfg(p_club);
  if p_logo is not null and (p_logo not like 'data:image/%' or length(p_logo) > 400000) then raise exception 'LOGO_INVALIDO'; end if;
  update public.lav_config set logo = p_logo, actualizado = now() where club_id = p_club;
  perform public._log(p_club, o.nombre, case when p_logo is null then 'Logo quitado' else 'Logo cambiado' end, '');
end $$;

create or replace function public.lav_servicio_guardar(p_club text, p_token uuid, p_id uuid, p_nombre text,
  p_auto int, p_suv int, p_moto int, p_activo boolean)
returns uuid language plpgsql security definer set search_path = public as $$
#variable_conflict use_variable
declare o public.operadores; v_id uuid := p_id;
begin
  o := public._admin(p_club, p_token);
  perform public._lav(p_club);
  if coalesce(trim(p_nombre), '') = '' then raise exception 'FALTA_NOMBRE'; end if;
  if coalesce(p_auto, 0) < 0 or coalesce(p_suv, 0) < 0 or coalesce(p_moto, 0) < 0 then raise exception 'MONTO_INVALIDO'; end if;
  if coalesce(p_auto, 0) + coalesce(p_suv, 0) + coalesce(p_moto, 0) = 0 then raise exception 'SIN_PRECIO'; end if;
  if v_id is null then
    insert into public.lav_servicios (club_id, nombre, p_auto, p_suv, p_moto, activo, orden)
      values (p_club, left(trim(p_nombre), 60), coalesce(p_auto, 0), coalesce(p_suv, 0), coalesce(p_moto, 0), coalesce(p_activo, true),
              (select coalesce(max(orden), 0) + 1 from public.lav_servicios where club_id = p_club))
      returning id into v_id;
  else
    update public.lav_servicios set nombre = left(trim(p_nombre), 60), p_auto = coalesce(p_auto, 0), p_suv = coalesce(p_suv, 0),
      p_moto = coalesce(p_moto, 0), activo = coalesce(p_activo, true)
      where id = v_id and club_id = p_club;
    if not found then raise exception 'NO_EXISTE'; end if;
  end if;
  perform public._log(p_club, o.nombre, case when p_id is null then 'Servicio agregado' else 'Servicio editado' end,
    trim(p_nombre) || ' · ' || public._gs(coalesce(p_auto, 0)) || ' / ' || public._gs(coalesce(p_suv, 0)) || ' / ' || public._gs(coalesce(p_moto, 0)));
  return v_id;
end $$;

-- Lista de ejemplo para arrancar (solo si el lavadero todavía no tiene servicios).
create or replace function public.lav_servicios_ejemplo(p_club text, p_token uuid)
returns int language plpgsql security definer set search_path = public as $$
declare o public.operadores;
begin
  o := public._admin(p_club, p_token);
  perform public._lav(p_club);
  if exists (select 1 from public.lav_servicios where club_id = p_club) then raise exception 'YA_HAY_SERVICIOS'; end if;
  insert into public.lav_servicios (club_id, nombre, p_auto, p_suv, p_moto, orden) values
    (p_club, 'Lavado exterior',   30000, 40000, 15000, 1),
    (p_club, 'Lavado completo',   50000, 70000, 25000, 2),
    (p_club, 'Aspirado interior', 20000, 25000, 0,     3),
    (p_club, 'Encerado',          60000, 80000, 30000, 4),
    (p_club, 'Lavado de motor',   40000, 50000, 0,     5);
  perform public._log(p_club, o.nombre, 'Servicios de ejemplo cargados', '5 servicios');
  return 5;
end $$;

-- ---------- clientes ----------
create or replace function public.lav_cliente_guardar(p_club text, p_token uuid, p_id uuid, p_nombre text, p_tel text, p_direccion text)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.operadores; v_id uuid := p_id;
begin
  o := public._op(p_club, p_token);
  perform public._lav(p_club);
  if coalesce(trim(p_nombre), '') = '' then raise exception 'FALTA_NOMBRE'; end if;
  if v_id is null then
    insert into public.lav_clientes (club_id, nombre, tel, tel_norm, direccion)
      values (p_club, left(trim(p_nombre), 60), left(trim(coalesce(p_tel, '')), 30), public._tel_norm(p_tel), left(trim(coalesce(p_direccion, '')), 120))
      returning id into v_id;
  else
    update public.lav_clientes set nombre = left(trim(p_nombre), 60), tel = left(trim(coalesce(p_tel, '')), 30),
      tel_norm = public._tel_norm(p_tel), direccion = left(trim(coalesce(p_direccion, '')), 120)
      where id = v_id and club_id = p_club;
    if not found then raise exception 'NO_EXISTE'; end if;
  end if;
  perform public._log(p_club, o.nombre, case when p_id is null then 'Cliente agregado' else 'Cliente editado' end, trim(p_nombre));
  return v_id;
end $$;

-- ---------- órdenes ----------
-- p = {chapa, tipo, marca, color, cliente_id?, nombre, tel, direccion, entrega, nota, servicios:[uuid,…]}
-- Los precios salen de lav_servicios (no del dispositivo) y quedan congelados en la orden.
create or replace function public.lav_orden_crear(p_club text, p_token uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o public.operadores; cfg public.lav_config; v public.lav_vehiculos; cl public.lav_clientes;
  v_chapa text := public._lav_chapa(p ->> 'chapa');
  v_tipo text := coalesce(nullif(p ->> 'tipo', ''), 'auto');
  v_entrega text := coalesce(nullif(p ->> 'entrega', ''), 'retira');
  v_dir text := left(trim(coalesce(p ->> 'direccion', '')), 120);
  v_nombre text := left(trim(coalesce(p ->> 'nombre', '')), 60);
  v_tel text := left(trim(coalesce(p ->> 'tel', '')), 30);
  v_servs jsonb; v_cant int; v_pedidos int; v_total int; v_num int; v_id uuid;
begin
  o := public._op(p_club, p_token);
  perform public._lav(p_club);
  if v_chapa !~ '^[A-Z0-9]{4,10}$' then raise exception 'CHAPA_INVALIDA'; end if;
  if v_tipo not in ('auto', 'suv', 'moto') then raise exception 'TIPO_INVALIDO'; end if;
  if v_entrega not in ('retira', 'delivery') then raise exception 'ENTREGA_INVALIDA'; end if;
  if v_entrega = 'delivery' and v_dir = '' then raise exception 'FALTA_DIRECCION'; end if;
  if exists (select 1 from public.lav_ordenes where club_id = p_club and chapa = v_chapa and estado in ('espera', 'lavando', 'listo')) then
    raise exception 'YA_EN_LOCAL';
  end if;

  select count(distinct x) into v_pedidos from jsonb_array_elements_text(coalesce(p -> 'servicios', '[]'::jsonb)) x;
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'nombre', s.nombre,
           'precio', case v_tipo when 'auto' then s.p_auto when 'suv' then s.p_suv else s.p_moto end) order by s.orden), '[]'::jsonb),
         count(*),
         coalesce(sum(case v_tipo when 'auto' then s.p_auto when 'suv' then s.p_suv else s.p_moto end), 0)
    into v_servs, v_cant, v_total
    from public.lav_servicios s
   where s.club_id = p_club and s.activo
     and s.id in (select x::uuid from jsonb_array_elements_text(coalesce(p -> 'servicios', '[]'::jsonb)) x)
     and (case v_tipo when 'auto' then s.p_auto when 'suv' then s.p_suv else s.p_moto end) > 0;
  if v_cant = 0 then raise exception 'SIN_SERVICIOS'; end if;
  if v_cant <> v_pedidos then raise exception 'SERVICIO_INVALIDO'; end if;

  -- cliente: el elegido, o el del teléfono, o el que ya tenía el vehículo
  select * into v from public.lav_vehiculos where club_id = p_club and chapa = v_chapa for update;
  if nullif(p ->> 'cliente_id', '') is not null then
    select * into cl from public.lav_clientes where id = (p ->> 'cliente_id')::uuid and club_id = p_club;
  end if;
  if cl.id is null and public._tel_norm(v_tel) <> '' then
    select * into cl from public.lav_clientes where club_id = p_club and tel_norm = public._tel_norm(v_tel) order by creado limit 1;
  end if;
  if cl.id is null and v.cliente_id is not null then
    select * into cl from public.lav_clientes where id = v.cliente_id and club_id = p_club;
  end if;
  if cl.id is not null then
    update public.lav_clientes set
      nombre = case when v_nombre <> '' then v_nombre else nombre end,
      tel = case when v_tel <> '' then v_tel else tel end,
      tel_norm = case when v_tel <> '' then public._tel_norm(v_tel) else tel_norm end,
      direccion = case when v_dir <> '' then v_dir else direccion end
    where id = cl.id returning * into cl;
  elsif v_nombre <> '' or v_tel <> '' then
    insert into public.lav_clientes (club_id, nombre, tel, tel_norm, direccion)
      values (p_club, coalesce(nullif(v_nombre, ''), 'Sin nombre'), v_tel, public._tel_norm(v_tel), v_dir)
      returning * into cl;
  end if;

  if v.id is null then
    insert into public.lav_vehiculos (club_id, chapa, tipo, marca, color, cliente_id)
      values (p_club, v_chapa, v_tipo, left(trim(coalesce(p ->> 'marca', '')), 40), left(trim(coalesce(p ->> 'color', '')), 30), cl.id)
      returning * into v;
  else
    update public.lav_vehiculos set tipo = v_tipo,
      marca = coalesce(nullif(left(trim(coalesce(p ->> 'marca', '')), 40), ''), marca),
      color = coalesce(nullif(left(trim(coalesce(p ->> 'color', '')), 30), ''), color),
      cliente_id = coalesce(cl.id, cliente_id)
    where id = v.id returning * into v;
  end if;

  cfg := public._lav_cfg(p_club);
  update public.lav_config set seq = seq + 1 where club_id = p_club returning seq into v_num;

  insert into public.lav_ordenes (club_id, num, vehiculo_id, cliente_id, chapa, tipo, servicios, total, entrega, direccion, nota, recibio)
    values (p_club, v_num, v.id, cl.id, v_chapa, v_tipo, v_servs, v_total, v_entrega,
            case when v_entrega = 'delivery' then v_dir else '' end, left(trim(coalesce(p ->> 'nota', '')), 200), o.nombre)
    returning id into v_id;
  perform public._log(p_club, o.nombre, 'Ingreso', '#' || v_num || ' · ' || v_chapa || ' · ' || public._gs(v_total));
  return jsonb_build_object('id', v_id, 'num', v_num);
end $$;

-- Avanza un paso. p_desde evita el doble toque: si otro dispositivo ya lo movió, no hace nada.
create or replace function public.lav_orden_avanzar(p_club text, p_token uuid, p_id uuid, p_desde text)
returns text language plpgsql security definer set search_path = public as $$
declare o public.operadores; r public.lav_ordenes;
begin
  o := public._op(p_club, p_token);
  perform public._lav(p_club);
  select * into r from public.lav_ordenes where id = p_id and club_id = p_club for update;
  if r.id is null then raise exception 'NO_EXISTE'; end if;
  if r.estado <> p_desde then raise exception 'YA_CAMBIO'; end if;
  if r.estado = 'espera' then
    update public.lav_ordenes set estado = 'lavando', t_lavando = now(), lavador = o.nombre, actualizado = now() where id = r.id;
    perform public._log(p_club, o.nombre, 'Empezó lavado', '#' || r.num || ' · ' || r.chapa);
    return 'lavando';
  elsif r.estado = 'lavando' then
    update public.lav_ordenes set estado = 'listo', t_listo = now(), actualizado = now() where id = r.id;
    perform public._log(p_club, o.nombre, 'Listo', '#' || r.num || ' · ' || r.chapa);
    return 'listo';
  end if;
  raise exception 'YA_CAMBIO';
end $$;

create or replace function public.lav_orden_retroceder(p_club text, p_token uuid, p_id uuid, p_desde text)
returns text language plpgsql security definer set search_path = public as $$
declare o public.operadores; r public.lav_ordenes;
begin
  o := public._op(p_club, p_token);
  perform public._lav(p_club);
  select * into r from public.lav_ordenes where id = p_id and club_id = p_club for update;
  if r.id is null then raise exception 'NO_EXISTE'; end if;
  if r.estado <> p_desde then raise exception 'YA_CAMBIO'; end if;
  if r.estado = 'lavando' then
    update public.lav_ordenes set estado = 'espera', t_lavando = null, lavador = '', actualizado = now() where id = r.id;
  elsif r.estado = 'listo' then
    update public.lav_ordenes set estado = 'lavando', t_listo = null, avisado = false, avisado_ts = null, actualizado = now() where id = r.id;
  elsif r.estado = 'entregado' then
    if o.rol <> 'admin' then raise exception 'SOLO_ADMIN'; end if;
    -- otra orden abierta con la misma chapa impediría volver atrás
    if exists (select 1 from public.lav_ordenes where club_id = p_club and chapa = r.chapa and id <> r.id and estado in ('espera', 'lavando', 'listo')) then
      raise exception 'YA_EN_LOCAL';
    end if;
    update public.lav_ordenes set estado = 'listo', t_entregado = null, actualizado = now() where id = r.id;
  else
    raise exception 'YA_CAMBIO';
  end if;
  perform public._log(p_club, o.nombre, 'Volvió un paso', '#' || r.num || ' · ' || r.chapa || ' · desde ' || r.estado);
  return (select estado from public.lav_ordenes where id = r.id);
end $$;

create or replace function public.lav_orden_avisado(p_club text, p_token uuid, p_id uuid, p_tipo text)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operadores; r public.lav_ordenes;
begin
  o := public._op(p_club, p_token);
  perform public._lav(p_club);
  if p_tipo not in ('retira', 'delivery') then raise exception 'ENTREGA_INVALIDA'; end if;
  update public.lav_ordenes set avisado = true, avisado_ts = now(), aviso_tipo = p_tipo,
    entrega = case when p_tipo = 'delivery' then 'delivery' else entrega end, actualizado = now()
    where id = p_id and club_id = p_club and estado not in ('cancelado')
    returning * into r;
  if r.id is null then raise exception 'NO_EXISTE'; end if;
  perform public._log(p_club, o.nombre, 'Aviso por WhatsApp', '#' || r.num || ' · ' || r.chapa || ' · ' || p_tipo);
end $$;

-- Cobra (si falta) y, si p_entregar, entrega. El pago adelantado se registra con p_entregar = false.
create or replace function public.lav_orden_cobrar(p_club text, p_token uuid, p_id uuid, p_metodo text, p_entregar boolean)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operadores; r public.lav_ordenes;
begin
  o := public._op(p_club, p_token);
  perform public._lav(p_club);
  select * into r from public.lav_ordenes where id = p_id and club_id = p_club for update;
  if r.id is null then raise exception 'NO_EXISTE'; end if;
  if r.estado in ('entregado', 'cancelado') then raise exception 'YA_CAMBIO'; end if;
  if not r.pagado then
    if p_metodo not in ('efectivo', 'transferencia', 'tarjeta', 'qr') then raise exception 'METODO_INVALIDO'; end if;
    update public.lav_ordenes set pagado = true, metodo = p_metodo, pagado_ts = now(), cobro = o.nombre, actualizado = now() where id = r.id;
    perform public._log(p_club, o.nombre, 'Cobro', '#' || r.num || ' · ' || r.chapa || ' · ' || public._gs(r.total) || ' · ' || p_metodo);
  end if;
  if p_entregar then
    if r.estado <> 'listo' then raise exception 'NO_LISTO'; end if;
    update public.lav_ordenes set estado = 'entregado', t_entregado = now(), actualizado = now() where id = r.id;
    perform public._log(p_club, o.nombre, 'Entregado', '#' || r.num || ' · ' || r.chapa);
  end if;
end $$;

create or replace function public.lav_orden_anular(p_club text, p_token uuid, p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operadores; r public.lav_ordenes;
begin
  o := public._op(p_club, p_token);
  perform public._lav(p_club);
  if coalesce(trim(p_motivo), '') = '' then raise exception 'FALTA_MOTIVO'; end if;
  select * into r from public.lav_ordenes where id = p_id and club_id = p_club for update;
  if r.id is null then raise exception 'NO_EXISTE'; end if;
  if r.estado in ('entregado', 'cancelado') then raise exception 'YA_CAMBIO'; end if;
  update public.lav_ordenes set estado = 'cancelado', motivo = left(trim(p_motivo), 200), cancelado_por = o.nombre,
    cancelado_ts = now(), actualizado = now() where id = r.id;
  perform public._log(p_club, o.nombre, 'Orden anulada', '#' || r.num || ' · ' || r.chapa || ' · ' || left(trim(p_motivo), 80)
    || case when r.pagado then ' · HABÍA PAGADO ' || public._gs(r.total) else '' end);
end $$;

-- ---------- estadísticas del panel: cada app muestra lo suyo ----------
create or replace function public.panel_clientes()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._solo_super();
  return coalesce((select jsonb_agg(x order by x.nombre) from (
    select c.id, c.nombre, c.app, c.estado, c.vence, c.gracia, c.cuota, c.contacto, c.tel, c.notas, c.creado, c.url,
      c.prueba, c.prueba_desde, c.apertura, c.cierre,
      (c.codigo_hash is not null) as tiene_codigo,
      public.club_habilitado(c.id) as habilitado,
      (select count(*) from public.dispositivos d where d.club_id = c.id and d.activo) as dispositivos,
      (select count(*) from public.operadores o where o.club_id = c.id and o.activo) as operadores,
      (select count(*) from public.canchas k where k.club_id = c.id) as canchas,
      greatest((select max(visto) from public.dispositivos d where d.club_id = c.id),
               (select max(ts) from public.historial h where h.club_id = c.id)) as ultimo_uso,
      case when c.app = 'lavadero' then
        (select count(*) from public.lav_ordenes l where l.club_id = c.id and l.estado <> 'cancelado'
           and (l.creado at time zone 'America/Asuncion')::date between public._hoy() - 30 and public._hoy())
      else
        (select count(*) from public.reservas r where r.club_id = c.id and r.estado <> 'cancelada'
           and r.fecha between public._hoy() - 30 and public._hoy())
      end as reservas_30,
      case when c.app = 'lavadero' then
        (select coalesce(sum(total), 0) from public.lav_ordenes l where l.club_id = c.id and l.pagado and l.estado <> 'cancelado'
           and l.pagado_ts > now() - interval '30 days')
      else
        (select coalesce(sum(monto), 0) from public.caja_movs m where m.club_id = c.id and m.ts > now() - interval '30 days')
      end as cobrado_30,
      (select max(ts) from public.pagos p where p.club_id = c.id) as ultimo_pago
    from public.clubs c) x), '[]'::jsonb);
end $$;

-- ---------- permisos (mismo cierre que 011, más los ayudantes nuevos) ----------
revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
revoke execute on function public._op(text, uuid), public._admin(text, uuid), public._nueva_sesion(text, uuid), public._log(text, text, text, text),
  public._caja_abierta(text), public._persona_ok(uuid, uuid), public._fijo_generar(public.turnos_fijos, date, date, text),
  public._lav(text), public._lav_cfg(text) from authenticated;
