-- TechConecta SV · Esquema para Supabase (PostgreSQL)
-- Pegar completo en: Supabase > SQL Editor > New query > Run

create type rol_usuario as enum ('cliente', 'tecnico');
create type estado_solicitud as enum ('pendiente', 'aceptada', 'completada', 'cancelada');

create table perfiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null,
  telefono text,
  rol rol_usuario not null default 'cliente',
  creado_en timestamptz not null default now()
);

create table tecnicos (
  id uuid primary key references perfiles(id) on delete cascade,
  especialidad text not null,
  zona text,
  verificado boolean not null default false,
  tarifa_hora numeric(8,2) check (tarifa_hora is null or tarifa_hora >= 0),
  latitud double precision check (latitud is null or latitud between -90 and 90),
  longitud double precision check (longitud is null or longitud between -180 and 180),
  disponible boolean not null default true,
  rating numeric(2,1) not null default 0
);

create table solicitudes (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references perfiles(id),
  tecnico_id uuid references tecnicos(id),
  especialidad text not null,
  descripcion text,
  latitud double precision,
  longitud double precision,
  estado estado_solicitud not null default 'pendiente',
  costo numeric(8,2) check (costo is null or costo >= 0),
  constraint solicitudes_latitud_valida
    check (latitud is null or latitud between -90 and 90),
  constraint solicitudes_longitud_valida
    check (longitud is null or longitud between -180 and 180),
  creado_en timestamptz not null default now()
);

create table resenas (
  id uuid primary key default gen_random_uuid(),
  solicitud_id uuid not null unique references solicitudes(id),
  cliente_id uuid not null references perfiles(id),
  tecnico_id uuid not null references tecnicos(id),
  calificacion int not null check (calificacion between 1 and 5),
  comentario text,
  creado_en timestamptz not null default now()
);

-- Una reseña por cada trabajo completado; sí se permiten reseñas de trabajos distintos.
create unique index if not exists resenas_una_por_solicitud on resenas (solicitud_id);

create index on solicitudes (cliente_id);
create index on solicitudes (tecnico_id);
create index on solicitudes (estado, especialidad);
create index on tecnicos (especialidad) where disponible;

-- Al registrarse en Supabase Auth se crea el perfil (y el técnico si aplica)
-- Metadatos esperados: nombre, telefono, rol, especialidad
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_rol rol_usuario;
begin
  if coalesce(new.raw_user_meta_data->>'rol', 'cliente')
     not in ('cliente', 'tecnico') then
    raise exception 'Rol inválido: debe ser cliente o tecnico';
  end if;
  v_rol := coalesce(new.raw_user_meta_data->>'rol', 'cliente')::rol_usuario;
  insert into perfiles (id, nombre, telefono, rol)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', 'Sin nombre'),
          new.raw_user_meta_data->>'telefono', v_rol);
  if v_rol = 'tecnico' then
    insert into tecnicos (id, especialidad)
    values (new.id, coalesce(new.raw_user_meta_data->>'especialidad', 'general'));
  end if;
  return new;
end $$;

create trigger on_auth_user_created
after insert on auth.users for each row execute function handle_new_user();

-- Recalcula el rating del técnico al insertar una reseña
create or replace function actualizar_rating() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update tecnicos
  set rating = (select round(avg(calificacion)::numeric, 1) from resenas where tecnico_id = new.tecnico_id)
  where id = new.tecnico_id;
  return new;
end $$;

create trigger on_resena_creada
after insert on resenas for each row execute function actualizar_rating();

-- Técnicos cercanos (fórmula de Haversine), ordenados por distancia
create or replace function buscar_tecnicos(
  p_lat double precision, p_lng double precision,
  p_especialidad text default null, p_radio_km double precision default 5
) returns table (id uuid, nombre text, especialidad text, rating numeric,
                 verificado boolean, tarifa_hora numeric, distancia_km double precision)
language sql stable as $$
  select t.id, p.nombre, t.especialidad, t.rating, t.verificado, t.tarifa_hora, d.km
  from tecnicos t
  join perfiles p on p.id = t.id
  cross join lateral (
    select 6371 * 2 * asin(sqrt(
      power(sin(radians(t.latitud - p_lat) / 2), 2) +
      cos(radians(p_lat)) * cos(radians(t.latitud)) *
      power(sin(radians(t.longitud - p_lng) / 2), 2))) as km
  ) d
  where p_radio_km >= 0
    and t.disponible and t.latitud is not null and t.longitud is not null
    and (p_especialidad is null or t.especialidad ilike p_especialidad)
    and d.km <= p_radio_km
  order by d.km;
$$;

-- ================= RLS =================
alter table perfiles    enable row level security;
alter table tecnicos    enable row level security;
alter table solicitudes enable row level security;
alter table resenas     enable row level security;

-- Perfiles: todos los autenticados ven; cada quien edita el suyo
create policy perfiles_select on perfiles for select to authenticated using (true);
create policy perfiles_update on perfiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Técnicos: todos ven; cada técnico edita su fila (ubicación, disponibilidad)
create policy tecnicos_select on tecnicos for select to authenticated using (true);
create policy tecnicos_update on tecnicos for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Solicitudes: un cliente NO puede ver ni modificar la solicitud de otro
create policy solicitudes_select on solicitudes for select to authenticated using (
  cliente_id = auth.uid()
  or tecnico_id = auth.uid()
  or (estado = 'pendiente' and exists (
        select 1 from tecnicos t where t.id = auth.uid() and t.especialidad ilike solicitudes.especialidad))
);
create policy solicitudes_insert on solicitudes for insert to authenticated
  with check (cliente_id = auth.uid());
create policy solicitudes_update on solicitudes for update to authenticated
  using (
    cliente_id = auth.uid()
    or tecnico_id = auth.uid()
    or (estado = 'pendiente' and exists (
          select 1 from tecnicos t where t.id = auth.uid() and t.especialidad ilike solicitudes.especialidad))
  )
  with check (cliente_id = auth.uid() or tecnico_id = auth.uid());

-- Reseñas: todos leen; solo el cliente de una solicitud completada puede reseñar
create policy resenas_select on resenas for select to authenticated using (true);
create policy resenas_insert on resenas for insert to authenticated with check (
  cliente_id = auth.uid()
  and exists (select 1 from solicitudes s
              where s.id = solicitud_id and s.cliente_id = auth.uid()
                and s.estado = 'completada' and s.tecnico_id = resenas.tecnico_id)
);

-- ================= SUPABASE STORAGE =================
-- Crear el bucket privado una sola vez (también puede hacerse desde Storage > New bucket).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos-perfil', 'fotos-perfil', false, 5242880,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy fotos_perfil_select on storage.objects
for select to authenticated
using (bucket_id = 'fotos-perfil');

create policy fotos_perfil_insert on storage.objects
for insert to authenticated
with check (
  bucket_id = 'fotos-perfil'
  and (storage.foldername(name))[1] = 'perfiles'
  and (storage.foldername(name))[2] = (select auth.uid()::text)
);

create policy fotos_perfil_update on storage.objects
for update to authenticated
using (
  bucket_id = 'fotos-perfil'
  and (storage.foldername(name))[1] = 'perfiles'
  and (storage.foldername(name))[2] = (select auth.uid()::text)
)
with check (
  bucket_id = 'fotos-perfil'
  and (storage.foldername(name))[1] = 'perfiles'
  and (storage.foldername(name))[2] = (select auth.uid()::text)
);

create policy fotos_perfil_delete on storage.objects
for delete to authenticated
using (
  bucket_id = 'fotos-perfil'
  and (storage.foldername(name))[1] = 'perfiles'
  and (storage.foldername(name))[2] = (select auth.uid()::text)
);
