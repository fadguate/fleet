-- ============================================================
-- Esquema de base de datos para M4 FAD - Flota de Autos
-- Ejecutar en Supabase → SQL Editor
-- ============================================================

-- 1) VEHÍCULOS
create table if not exists vehicles (
  id uuid primary key default gen_random_uuid(),
  plate text not null unique,
  type text not null,
  brand text not null,
  model text not null,
  color text,
  capacity int not null default 1,
  photo text, -- URL de la foto (ver nota sobre Storage al final)
  created_at timestamptz not null default now()
);

-- 2) CLAVES DE ACCESO / USUARIOS
create table if not exists access_codes (
  code text primary key,
  role text not null check (role in ('admin','usuario')),
  owner text not null,
  email text not null,
  license_expiry date,
  created_at timestamptz not null default now()
);

-- 3) RESERVAS
create table if not exists reservations (
  id text primary key, -- código alfanumérico de 7 caracteres (#XXXXXXX)
  vehicle_id uuid not null references vehicles(id) on delete cascade,
  user_name text not null,
  user_email text,
  created_by text not null, -- código de acceso o correo de quien reservó
  start_date date not null,
  end_date date not null,
  start_time time not null,
  end_time time not null,
  full_day boolean not null default false,
  purpose text,
  has_companions boolean not null default false,
  companions text,
  observations text,
  license_expiry date, -- vencimiento de licencia del solicitante al momento de reservar
  created_at timestamptz not null default now()
);

-- 4) BLOQUEOS POR MANTENIMIENTO
create table if not exists maintenance_blocks (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references vehicles(id) on delete cascade,
  start_date date not null,
  end_date date not null,
  start_time time not null default '00:00',
  end_time time not null default '23:59',
  reason text not null,
  created_by text,
  created_at timestamptz not null default now()
);

-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- Bloqueamos el acceso directo a access_codes (contiene las
-- claves) y sólo permitimos validarlas mediante una función.
-- ============================================================
alter table vehicles enable row level security;
alter table reservations enable row level security;
alter table maintenance_blocks enable row level security;
alter table access_codes enable row level security;

-- Vehículos, reservas y mantenimiento: lectura/escritura pública
-- (ya que el control de acceso lo hace la app con las claves).
-- Puedes endurecer esto más adelante si lo necesitas.
create policy "vehicles_all" on vehicles for all using (true) with check (true);
create policy "reservations_all" on reservations for all using (true) with check (true);
create policy "maintenance_all" on maintenance_blocks for all using (true) with check (true);

-- access_codes: SIN políticas públicas → nadie puede hacer
-- SELECT/INSERT/UPDATE directo desde el navegador. Todo pasa
-- por la función RPC de abajo.

-- ============================================================
-- FUNCIÓN SEGURA PARA VALIDAR LOGIN
-- Devuelve solo lo necesario (rol, licencia) sin exponer la
-- clave real de nadie más.
-- ============================================================
create or replace function validate_access_code(input_code text)
returns table(role text, license_expiry date, code text)
language sql
security definer
set search_path = public
as $$
  select role, license_expiry, code
  from access_codes
  where lower(code) = lower(input_code)
  limit 1;
$$;

-- Función para que el admin cree nuevas claves (evita exponer
-- INSERT directo sobre access_codes al público).
create or replace function create_access_code(
  p_code text, p_role text, p_owner text, p_email text, p_license_expiry date
) returns void
language sql
security definer
set search_path = public
as $$
  insert into access_codes(code, role, owner, email, license_expiry)
  values (upper(p_code), p_role, p_owner, p_email, p_license_expiry);
$$;

-- Función para buscar una clave por correo (recuperación).
create or replace function find_code_by_email(input_email text)
returns table(code text)
language sql
security definer
set search_path = public
as $$
  select code from access_codes where lower(email) = lower(input_email) limit 1;
$$;

-- ============================================================
-- DATOS INICIALES (opcional, para probar)
-- ============================================================
insert into access_codes(code, role, owner, email, license_expiry) values
  ('ADMIN-2026','admin','Administrador general','admin@empresa.com', current_date + interval '400 days'),
  ('USER-2026','usuario','Colaborador','colaborador@empresa.com', current_date + interval '60 days')
on conflict (code) do nothing;

insert into vehicles(plate,type,brand,model,color,capacity) values
  ('ABC-123','Sedán','Toyota','Corolla','Blanco',5),
  ('XYZ-789','Camioneta','Chevrolet','Silverado','Gris',5),
  ('DEF-456','Van','Hyundai','H1','Azul',11),
  ('GHI-321','Motocicleta','Yamaha','FZ','Negro',2)
on conflict (plate) do nothing;
