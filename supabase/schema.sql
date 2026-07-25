-- ============================================================
--  Mapa do Cocó — Lisboa
--  Schéma Postgres / Supabase
--
--  Principe directeur : RIEN N'EST JAMAIS SUPPRIMÉ.
--  Un signalement est un fait horodaté immuable. Ce qui change,
--  c'est son POIDS à l'affichage (décroissance temporelle) et
--  son STATUT (nettoyé / reconfirmé), lui-même dérivé d'un
--  journal d'événements append-only.
--
--  À exécuter dans le SQL Editor de Supabase.
-- ============================================================

create extension if not exists "pgcrypto";

-- ------------------------------------------------------------
-- 1. Paramétrage par freguesia
--    La demi-vie reflète la fréquence réelle de nettoyage :
--    en Baixa le balayage est quotidien, à Marvila non.
--    Un signalement doit donc s'éteindre plus vite en Baixa.
-- ------------------------------------------------------------
create table if not exists freguesia_config (
  name             text primary key,
  half_life_hours  numeric not null default 48,
  notes            text
);

insert into freguesia_config (name, half_life_hours, notes) values
  ('Santa Maria Maior',        24, 'Baixa/Alfama — balayage quotidien, forte fréquentation'),
  ('Misericórdia',             24, 'Bairro Alto/Chiado — nettoyage quotidien'),
  ('Santo António',            24, null),
  ('Arroios',                  36, null),
  ('São Vicente',              36, null),
  ('Penha de França',          48, null),
  ('Estrela',                  48, null),
  ('Campo de Ourique',         48, null),
  ('Avenidas Novas',           48, null),
  ('Areeiro',                  48, null),
  ('Alvalade',                 48, null),
  ('Campolide',                48, null),
  ('Alcântara',                48, null),
  ('Ajuda',                    72, null),
  ('Belém',                    72, null),
  ('São Domingos de Benfica',  72, null),
  ('Benfica',                  72, null),
  ('Carnide',                  72, null),
  ('Lumiar',                   72, null),
  ('Olivais',                  72, null),
  ('Parque das Nações',        72, null),
  ('Beato',                    96, 'Desserte moins fréquente'),
  ('Marvila',                  96, 'Desserte moins fréquente'),
  ('Santa Clara',              96, 'Desserte moins fréquente')
on conflict (name) do nothing;

-- ------------------------------------------------------------
-- 2. Signalements
--    `status` et `cleaned_at` sont dénormalisés depuis
--    report_events pour que la lecture reste rapide.
--    Aucune donnée personnelle : device_hash est un UUID
--    aléatoire généré côté client, jamais un identifiant réel.
-- ------------------------------------------------------------
create table if not exists reports (
  id          uuid primary key default gen_random_uuid(),
  lat         double precision not null,
  lng         double precision not null,
  freguesia   text references freguesia_config(name),
  created_at  timestamptz not null default now(),
  status      text not null default 'open' check (status in ('open', 'cleaned')),
  cleaned_at  timestamptz,
  confirms    integer not null default 0,   -- nb de « encore là »
  device_hash text not null,
  is_demo     boolean not null default false
);

create index if not exists reports_created_idx   on reports (created_at desc);
create index if not exists reports_freguesia_idx on reports (freguesia);
create index if not exists reports_status_idx    on reports (status);
create index if not exists reports_device_idx    on reports (device_hash, created_at desc);

-- ------------------------------------------------------------
-- 3. Journal d'événements — append-only, source de vérité
--    On ne fait jamais de DELETE ni d'UPDATE ici. C'est ce qui
--    permet de rejouer l'historique et de calculer les délais
--    de nettoyage a posteriori.
-- ------------------------------------------------------------
create table if not exists report_events (
  id          bigserial primary key,
  report_id   uuid not null references reports(id) on delete cascade,
  kind        text not null check (kind in ('created', 'cleaned', 'confirmed')),
  created_at  timestamptz not null default now(),
  device_hash text not null
);

create index if not exists events_report_idx on report_events (report_id, created_at);

-- ------------------------------------------------------------
-- 4. Poids temporel — le cœur du modèle
--    Décroissance exponentielle par demi-vie. Un point nettoyé
--    tombe à 0 immédiatement mais reste en base pour toujours.
-- ------------------------------------------------------------
create or replace function report_weight(
  p_created_at timestamptz,
  p_status     text,
  p_freguesia  text
) returns numeric
language sql stable as $$
  select case
    when p_status = 'cleaned' then 0
    else power(
      0.5,
      (extract(epoch from (now() - p_created_at)) / 3600.0)
      / coalesce((select half_life_hours from freguesia_config where name = p_freguesia), 48)
    )
  end;
$$;

-- ------------------------------------------------------------
-- 5. Vue « live » — ce qui est probablement là maintenant
--    En dessous de 0.05 (≈ 4 demi-vies) le point est
--    visuellement mort : on l'écarte de l'affichage, sans
--    jamais le retirer de la base.
-- ------------------------------------------------------------
create or replace view v_active_reports as
select
  r.*,
  report_weight(r.created_at, r.status, r.freguesia) as weight
from reports r
where report_weight(r.created_at, r.status, r.freguesia) > 0.05;

-- ------------------------------------------------------------
-- 6. Vue « chronique » — les points noirs récurrents
--    Aucune décroissance : c'est la mémoire longue, celle qui
--    a une valeur politique face à la mairie.
-- ------------------------------------------------------------
create or replace view v_freguesia_stats as
select
  f.name                                                             as freguesia,
  count(r.id)                                                        as total_all_time,
  count(r.id) filter (where r.created_at > now() - interval '30 days') as last_30d,
  coalesce(sum(report_weight(r.created_at, r.status, r.freguesia)), 0)::numeric(10,2) as active_now,
  count(r.id) filter (where r.status = 'cleaned')                    as cleaned_total,
  -- Délai médian signalement → nettoyage : l'indicateur de
  -- performance du service public que personne d'autre ne produit.
  percentile_cont(0.5) within group (
    order by extract(epoch from (r.cleaned_at - r.created_at)) / 3600.0
  ) filter (where r.cleaned_at is not null)::numeric(10,1)           as median_cleanup_hours,
  max(r.confirms)                                                    as worst_recurrence
from freguesia_config f
left join reports r on r.freguesia = f.name and not r.is_demo
group by f.name;

-- ============================================================
-- 7. Écritures : uniquement par RPC.
--    Le client anonyme ne peut ni UPDATE ni DELETE directement.
--    Toute la validation (bbox, anti-spam) est côté serveur —
--    une validation côté client ne protège de rien.
-- ============================================================

-- Bbox du municipe de Lisbonne (généreuse). Tout point hors
-- de cette zone est un bug ou un troll.
create or replace function in_lisbon(p_lat double precision, p_lng double precision)
returns boolean language sql immutable as $$
  select p_lat between 38.68 and 38.81 and p_lng between -9.25 and -9.08;
$$;

create or replace function create_report(
  p_lat         double precision,
  p_lng         double precision,
  p_freguesia   text,
  p_device_hash text
) returns uuid
language plpgsql security definer as $$
declare
  v_id uuid;
  v_recent integer;
  v_dupe integer;
begin
  if not in_lisbon(p_lat, p_lng) then
    raise exception 'Hors des limites de Lisbonne';
  end if;

  -- Anti-spam : 20 signalements/heure par appareil. Le jour où
  -- l'app marche, quelqu'un essaiera de noyer une rue qu'il
  -- n'aime pas.
  select count(*) into v_recent
  from reports
  where device_hash = p_device_hash and created_at > now() - interval '1 hour';
  if v_recent >= 20 then
    raise exception 'Trop de signalements — réessaie dans une heure';
  end if;

  -- Anti-doublon : même appareil, même endroit (~15 m), <10 min.
  select count(*) into v_dupe
  from reports
  where device_hash = p_device_hash
    and created_at > now() - interval '10 minutes'
    and abs(lat - p_lat) < 0.00014 and abs(lng - p_lng) < 0.00018;
  if v_dupe > 0 then
    raise exception 'Déjà signalé à cet endroit il y a moins de 10 minutes';
  end if;

  insert into reports (lat, lng, freguesia, device_hash)
  values (p_lat, p_lng, p_freguesia, p_device_hash)
  returning id into v_id;

  insert into report_events (report_id, kind, device_hash)
  values (v_id, 'created', p_device_hash);

  return v_id;
end;
$$;

create or replace function mark_cleaned(p_report_id uuid, p_device_hash text)
returns void
language plpgsql security definer as $$
begin
  update reports
     set status = 'cleaned', cleaned_at = now()
   where id = p_report_id and status = 'open';

  insert into report_events (report_id, kind, device_hash)
  values (p_report_id, 'cleaned', p_device_hash);
end;
$$;

-- « Encore là » : le signal inverse, celui qu'on oublie toujours
-- de prévoir. Remet le compteur à zéro (poids plein) ET
-- incrémente la récidive. 3 confirmations en 10 jours = point noir.
create or replace function confirm_still_there(p_report_id uuid, p_device_hash text)
returns void
language plpgsql security definer as $$
begin
  update reports
     set created_at = now(),
         status     = 'open',
         cleaned_at = null,
         confirms   = confirms + 1
   where id = p_report_id;

  insert into report_events (report_id, kind, device_hash)
  values (p_report_id, 'confirmed', p_device_hash);
end;
$$;

-- ------------------------------------------------------------
-- 8. Row Level Security
--    Lecture publique, écriture uniquement via les RPC ci-dessus.
-- ------------------------------------------------------------
alter table reports       enable row level security;
alter table report_events enable row level security;
alter table freguesia_config enable row level security;

drop policy if exists "lecture publique" on reports;
create policy "lecture publique" on reports for select using (true);

drop policy if exists "lecture publique" on report_events;
create policy "lecture publique" on report_events for select using (true);

drop policy if exists "lecture publique" on freguesia_config;
create policy "lecture publique" on freguesia_config for select using (true);

-- Aucune policy insert/update/delete : le client anonyme ne peut
-- écrire que par les fonctions security definer.

grant execute on function create_report(double precision, double precision, text, text) to anon, authenticated;
grant execute on function mark_cleaned(uuid, text) to anon, authenticated;
grant execute on function confirm_still_there(uuid, text) to anon, authenticated;
