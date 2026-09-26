-- =====================================================================
--  Repas en famille — base de données Supabase
--  À coller dans Supabase > SQL Editor > New query, puis « Run ».
--  Peut être ré-exécuté après une modification : les données sont gardées.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- ---------------------------------------------------------------------
--  Tables
-- ---------------------------------------------------------------------
create table if not exists membres (
  id            text primary key,
  prenom        text not null,
  emoji         text not null default '🙂',
  couleur       text not null check (couleur in ('rose','bleu')),
  parent        boolean not null default false,
  priorite      int not null default 0,          -- choix du repas : la plus haute priorité l'emporte (Nadine)
  ordre         int not null default 0,
  pin_hash      text,
  echecs        int not null default 0,
  bloque_jusqua timestamptz,
  aime          text not null default '',
  naime_pas     text[] not null default '{}',
  allergies     text[] not null default '{}',
  sujet_ntfy    text not null default ('repas-' || replace(gen_random_uuid()::text, '-', ''))
);

create table if not exists sessions (
  jeton  uuid primary key default gen_random_uuid(),
  membre text not null references membres(id) on delete cascade,
  cree   timestamptz not null default now()
);

create table if not exists presences (
  jour       date not null,
  membre     text not null references membres(id) on delete cascade,
  souper     text check (souper in ('present','absent')),
  souper_maj timestamptz,
  souper_par text,
  lunch      text check (lunch in ('aucun','froid','chaud')),
  lunch_maj  timestamptz,
  lunch_par  text,
  primary key (jour, membre)
);

create table if not exists invites (
  id         uuid primary key default gen_random_uuid(),
  jour       date not null,
  nom        text not null,
  allergies  text[] not null default '{}',
  naime_pas  text[] not null default '{}',
  invite_par text not null references membres(id),
  cree       timestamptz not null default now()
);

create table if not exists suggestions (
  id          uuid primary key default gen_random_uuid(),
  jour        date not null,
  titre       text not null,
  ingredients text not null default '',
  propose_par text not null references membres(id),
  cree        timestamptz not null default now(),
  choisi      boolean not null default false,
  choisi_par  text references membres(id),
  choisi_le   timestamptz
);

create table if not exists journal (
  id     bigserial primary key,
  quand  timestamptz not null default now(),
  par    text,
  membre text,
  jour   date,
  texte  text not null
);

create table if not exists reglages (
  cle    text primary key,
  valeur text
);

create table if not exists horaires_souper (
  jour        date primary key,
  heure       time not null,
  modifie_par text references membres(id) on delete set null,
  modifie_le  timestamptz not null default now()
);

create index if not exists presences_jour on presences (jour);
create index if not exists invites_jour on invites (jour);
create index if not exists suggestions_jour on suggestions (jour);
create index if not exists journal_quand on journal (quand desc);

-- Aucun accès direct aux tables depuis Internet : tout passe par les
-- fonctions ci-dessous, qui vérifient la session (NIP).
alter table membres     enable row level security;
alter table sessions    enable row level security;
alter table presences   enable row level security;
alter table invites     enable row level security;
alter table suggestions enable row level security;
alter table journal     enable row level security;
alter table reglages    enable row level security;
alter table horaires_souper enable row level security;

-- ---------------------------------------------------------------------
--  Données de départ (ne remplace rien si déjà présent)
-- ---------------------------------------------------------------------
insert into reglages (cle, valeur) values
  ('fuseau',        'America/Toronto'),
  ('heure_limite',  '11'),
  ('heure_rappel',  '10'),
  ('serveur_ntfy',  'https://ntfy.sh'),
  ('url_app',       ''),
  ('sujet_parents', 'repas-parents-' || replace(gen_random_uuid()::text, '-', ''))
on conflict (cle) do nothing;

insert into membres (id, prenom, emoji, couleur, parent, priorite, ordre, naime_pas) values
  ('marc',      'Marc',      '🧔',    'bleu', true,  1, 1, '{}'),
  ('nadine',    'Nadine',    '👩',    'rose', true,  2, 2, '{"ragoût","porc"}'),
  ('aleck',     'Aleck',     '🧑',    'bleu', false, 0, 3, '{"tout ce qui vient de la mer"}'),
  ('william',   'William',   '👱',    'bleu', false, 0, 4, '{"jambon"}'),
  ('raphaelle', 'Raphaelle', '👩‍🦰', 'rose', false, 0, 5, '{}')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
--  Fonctions internes
-- ---------------------------------------------------------------------
create or replace function _reglage(p text) returns text
language sql stable security definer set search_path = public as $$
  select valeur from reglages where cle = p
$$;

create or replace function _maintenant() returns timestamp
language sql stable security definer set search_path = public as $$
  select now() at time zone _reglage('fuseau')
$$;

create or replace function _aujourdhui() returns date
language sql stable security definer set search_path = public as $$
  select _maintenant()::date
$$;

create or replace function _jour_fr(d date) returns text
language sql immutable as $$
  select (array['dimanche','lundi','mardi','mercredi','jeudi','vendredi','samedi'])[extract(dow from d)::int + 1]
      || ' ' || extract(day from d)::int || ' '
      || (array['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'])[extract(month from d)::int]
$$;

create or replace function _heure_fr(t timestamptz) returns text
language sql stable security definer set search_path = public as $$
  select extract(hour from t at time zone _reglage('fuseau'))::int || 'h'
      || lpad(extract(minute from t at time zone _reglage('fuseau'))::int::text, 2, '0')
$$;

create or replace function _qui(p_jeton uuid) returns membres
language plpgsql stable security definer set search_path = public as $$
declare m membres;
begin
  select mb.* into m from sessions s join membres mb on mb.id = s.membre where s.jeton = p_jeton;
  if not found then raise exception 'SESSION_INVALIDE'; end if;
  return m;
end $$;

create or replace function _notifier(p_sujet text, p_titre text, p_message text, p_tag text default 'fork_and_knife', p_priorite int default 3)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if coalesce(p_sujet, '') = '' then return; end if;
  perform net.http_post(
    url     := _reglage('serveur_ntfy'),
    body    := jsonb_build_object('topic', p_sujet, 'title', p_titre, 'message', p_message,
                                  'tags', jsonb_build_array(p_tag), 'priority', p_priorite)
               || case when coalesce(_reglage('url_app'), '') <> ''
                       then jsonb_build_object('click', _reglage('url_app')) else '{}'::jsonb end,
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
end $$;

create or replace function _choisir(m membres, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s suggestions; cur suggestions; cp membres;
begin
  if not m.parent then raise exception 'Seuls Nadine et Marc peuvent choisir le repas officiel.'; end if;
  select * into s from suggestions where id = p_id;
  if not found then raise exception 'Suggestion introuvable.'; end if;
  select * into cur from suggestions where jour = s.jour and choisi limit 1;
  if found then
    if cur.id = s.id then return; end if;
    select * into cp from membres where id = cur.choisi_par;
    if cp.priorite > m.priorite then
      raise exception '% a déjà choisi le repas de ce jour; son choix a priorité.', cp.prenom;
    end if;
    update suggestions set choisi = false, choisi_par = null, choisi_le = null where id = cur.id;
  end if;
  update suggestions set choisi = true, choisi_par = m.id, choisi_le = now() where id = s.id;
  insert into journal (par, membre, jour, texte)
    values (m.id, m.id, s.jour, 'Repas choisi pour le souper du ' || _jour_fr(s.jour) || ' : ' || s.titre);
end $$;

-- ---------------------------------------------------------------------
--  Fonctions appelées par l'application
-- ---------------------------------------------------------------------
create or replace function list_membres() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'prenom', prenom, 'emoji', emoji, 'couleur', couleur,
                                               'parent', parent, 'a_nip', pin_hash is not null) order by ordre), '[]')
  from membres
$$;

create or replace function connexion(p_membre text, p_nip text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m membres; j uuid;
begin
  if p_nip is null or p_nip !~ '^[0-9]{4}$' then return jsonb_build_object('erreur', 'Le NIP doit contenir 4 chiffres.'); end if;
  select * into m from membres where id = p_membre for update;
  if not found then return jsonb_build_object('erreur', 'Membre inconnu.'); end if;
  if m.bloque_jusqua is not null and m.bloque_jusqua > now() then
    return jsonb_build_object('erreur', 'Trop d''essais. Réessaie dans 15 minutes.');
  end if;
  if m.bloque_jusqua is not null then
    update membres set echecs = 0, bloque_jusqua = null where id = m.id;
    m.echecs := 0;
  end if;
  if m.pin_hash is null then
    update membres set pin_hash = crypt(p_nip, gen_salt('bf')), echecs = 0 where id = m.id;
  elsif crypt(p_nip, m.pin_hash) <> m.pin_hash then
    update membres set echecs = m.echecs + 1,
                       bloque_jusqua = case when m.echecs + 1 >= 5 then now() + interval '15 minutes' end
     where id = m.id;
    return jsonb_build_object('erreur', 'NIP incorrect.');
  else
    update membres set echecs = 0 where id = m.id;
  end if;
  insert into sessions (membre) values (m.id) returning jeton into j;
  return jsonb_build_object('jeton', j);
end $$;

create or replace function deconnexion(p_jeton uuid) returns void
language sql security definer set search_path = public as $$
  delete from sessions where jeton = p_jeton
$$;

create or replace function donnees(p_jeton uuid, p_debut date, p_fin date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m membres := _qui(p_jeton);
begin
  return jsonb_build_object(
    'moi', m.id,
    'heure_limite', _reglage('heure_limite')::int,
    'heure_rappel', _reglage('heure_rappel')::int,
    'sujet_parents', case when m.parent then _reglage('sujet_parents') end,
    'membres', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', id, 'prenom', prenom, 'emoji', emoji, 'couleur', couleur, 'parent', parent,
                  'priorite', priorite, 'aime', aime, 'naime_pas', naime_pas, 'allergies', allergies,
                  'sujet_ntfy', case when id = m.id then sujet_ntfy end) order by ordre), '[]') from membres),
    'presences',   (select coalesce(jsonb_agg(to_jsonb(p)), '[]') from presences p where jour between p_debut and p_fin),
    'invites',     (select coalesce(jsonb_agg(to_jsonb(i)), '[]') from invites i where jour between p_debut and p_fin),
    'suggestions', (select coalesce(jsonb_agg(to_jsonb(s)), '[]') from suggestions s where jour between p_debut and p_fin),
    'horaires_souper', (select coalesce(jsonb_agg(jsonb_build_object('jour', jour, 'heure', to_char(heure, 'HH24:MI'))), '[]') from horaires_souper where jour between p_debut and p_fin),
    'journal',     (select coalesce(jsonb_agg(to_jsonb(x) order by x.quand desc), '[]')
                      from (select * from journal order by quand desc limit 40) x)
  );
end $$;

create or replace function enregistrer_heure_souper(p_jeton uuid, p_jour date, p_heure text) returns void
language plpgsql security definer set search_path = public as $$
declare m membres := _qui(p_jeton);
begin
  if p_jour < _aujourdhui() then raise exception 'Cette journée est passée.'; end if;
  if coalesce(trim(p_heure), '') = '' then
    delete from horaires_souper where jour = p_jour;
    insert into journal (par, membre, jour, texte) values (m.id, m.id, p_jour, 'Heure du souper retirée');
    return;
  end if;
  if p_heure !~ '^(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Indique une heure valide.'; end if;
  insert into horaires_souper (jour, heure, modifie_par, modifie_le)
    values (p_jour, p_heure::time, m.id, now())
    on conflict (jour) do update set heure = excluded.heure, modifie_par = m.id, modifie_le = now();
  insert into journal (par, membre, jour, texte) values (m.id, m.id, p_jour, 'Heure du souper fixée à ' || p_heure);
end $$;

create or replace function enregistrer_presence(p_jeton uuid, p_membre text, p_jour date, p_champ text, p_valeur text)
returns void language plpgsql security definer set search_path = public as $$
declare
  m membres := _qui(p_jeton);
  cible membres;
  ancien text;
  libelle text;
begin
  if m.id <> p_membre and not m.parent then raise exception 'Tu ne peux modifier que ta propre présence.'; end if;
  if p_jour < _aujourdhui() then raise exception 'Cette journée est passée.'; end if;
  select * into cible from membres where id = p_membre;
  if not found then raise exception 'Membre inconnu.'; end if;

  if p_champ = 'souper' then
    if p_valeur not in ('present','absent') then raise exception 'Valeur invalide.'; end if;
    select souper into ancien from presences where jour = p_jour and membre = p_membre;
    if ancien is not distinct from p_valeur then return; end if;
    insert into presences (jour, membre, souper, souper_maj, souper_par) values (p_jour, p_membre, p_valeur, now(), m.id)
      on conflict (jour, membre) do update set souper = excluded.souper, souper_maj = now(), souper_par = m.id;
    libelle := 'Souper du ' || _jour_fr(p_jour) || ' : ' || case p_valeur when 'present' then 'présent(e)' else 'absent(e)' end;
  elsif p_champ = 'lunch' then
    if p_valeur not in ('aucun','froid','chaud') then raise exception 'Valeur invalide.'; end if;
    select lunch into ancien from presences where jour = p_jour and membre = p_membre;
    if ancien is not distinct from p_valeur then return; end if;
    insert into presences (jour, membre, lunch, lunch_maj, lunch_par) values (p_jour, p_membre, p_valeur, now(), m.id)
      on conflict (jour, membre) do update set lunch = excluded.lunch, lunch_maj = now(), lunch_par = m.id;
    libelle := 'Lunch du ' || _jour_fr(p_jour) || ' : '
            || case p_valeur when 'aucun' then 'aucun' when 'froid' then 'froid (école)' else 'chaud (maison)' end;
  else
    raise exception 'Champ invalide.';
  end if;

  insert into journal (par, membre, jour, texte) values (m.id, p_membre, p_jour, libelle);

  -- Annulation d'une présence déjà confirmée : avis aux parents
  if (p_champ = 'souper' and ancien = 'present' and p_valeur = 'absent')
     or (p_champ = 'lunch' and ancien in ('froid','chaud') and p_valeur = 'aucun') then
    perform _notifier(
      _reglage('sujet_parents'),
      '❌ ' || cible.prenom || ' annule',
      libelle || ' — changement fait à ' || _heure_fr(now())
        || case when m.id <> cible.id then ' par ' || m.prenom else '' end || '.',
      'x', 4);
  end if;
end $$;

create or replace function enregistrer_invite(p_jeton uuid, p_id uuid, p_jour date, p_nom text, p_allergies text[], p_naime_pas text[])
returns uuid language plpgsql security definer set search_path = public as $$
declare m membres := _qui(p_jeton); g invites; nid uuid;
begin
  if coalesce(trim(p_nom), '') = '' then raise exception 'Indique le nom de la personne invitée.'; end if;
  if p_id is null then
    if p_jour < _aujourdhui() then raise exception 'Cette journée est passée.'; end if;
    insert into invites (jour, nom, allergies, naime_pas, invite_par)
      values (p_jour, trim(p_nom), coalesce(p_allergies, '{}'), coalesce(p_naime_pas, '{}'), m.id) returning id into nid;
    insert into journal (par, membre, jour, texte)
      values (m.id, m.id, p_jour, 'Invité(e) au souper du ' || _jour_fr(p_jour) || ' : ' || trim(p_nom));
    return nid;
  end if;
  select * into g from invites where id = p_id;
  if not found then raise exception 'Invité introuvable.'; end if;
  if g.invite_par <> m.id and not m.parent then raise exception 'Seule la personne qui a invité ou un parent peut modifier cet invité.'; end if;
  update invites set nom = trim(p_nom), allergies = coalesce(p_allergies, '{}'), naime_pas = coalesce(p_naime_pas, '{}') where id = p_id;
  return p_id;
end $$;

create or replace function supprimer_invite(p_jeton uuid, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m membres := _qui(p_jeton); g invites;
begin
  select * into g from invites where id = p_id;
  if not found then return; end if;
  if g.invite_par <> m.id and not m.parent then raise exception 'Seule la personne qui a invité ou un parent peut retirer cet invité.'; end if;
  delete from invites where id = p_id;
  insert into journal (par, membre, jour, texte)
    values (m.id, g.invite_par, g.jour, 'Invité(e) retiré(e) du souper du ' || _jour_fr(g.jour) || ' : ' || g.nom);
end $$;

create or replace function proposer_repas(p_jeton uuid, p_jour date, p_titre text, p_ingredients text, p_choisir boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare m membres := _qui(p_jeton); nid uuid;
begin
  if coalesce(trim(p_titre), '') = '' then raise exception 'Indique le nom du repas.'; end if;
  if p_jour < _aujourdhui() then raise exception 'Cette journée est passée.'; end if;
  insert into suggestions (jour, titre, ingredients, propose_par)
    values (p_jour, trim(p_titre), coalesce(trim(p_ingredients), ''), m.id) returning id into nid;
  insert into journal (par, membre, jour, texte)
    values (m.id, m.id, p_jour, 'Suggestion pour le souper du ' || _jour_fr(p_jour) || ' : ' || trim(p_titre));
  if p_choisir then perform _choisir(m, nid); end if;
  return nid;
end $$;

create or replace function choisir_repas(p_jeton uuid, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _choisir(_qui(p_jeton), p_id);
end $$;

create or replace function retirer_choix(p_jeton uuid, p_jour date) returns void
language plpgsql security definer set search_path = public as $$
declare m membres := _qui(p_jeton); cur suggestions; cp membres;
begin
  if not m.parent then raise exception 'Seuls Nadine et Marc peuvent changer le repas officiel.'; end if;
  select * into cur from suggestions where jour = p_jour and choisi limit 1;
  if not found then return; end if;
  select * into cp from membres where id = cur.choisi_par;
  if cp.priorite > m.priorite then raise exception 'Le choix de % a priorité.', cp.prenom; end if;
  update suggestions set choisi = false, choisi_par = null, choisi_le = null where id = cur.id;
  insert into journal (par, membre, jour, texte)
    values (m.id, m.id, p_jour, 'Choix de repas retiré pour le ' || _jour_fr(p_jour) || ' : ' || cur.titre);
end $$;

create or replace function supprimer_suggestion(p_jeton uuid, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m membres := _qui(p_jeton); s suggestions; cp membres;
begin
  select * into s from suggestions where id = p_id;
  if not found then return; end if;
  if s.propose_par <> m.id and not m.parent then raise exception 'Seule la personne qui a suggéré ou un parent peut supprimer.'; end if;
  if s.choisi then
    if not m.parent then raise exception 'Ce repas est déjà choisi; seul un parent peut le retirer.'; end if;
    select * into cp from membres where id = s.choisi_par;
    if cp.priorite > m.priorite then raise exception 'Le choix de % a priorité.', cp.prenom; end if;
  end if;
  delete from suggestions where id = p_id;
  insert into journal (par, membre, jour, texte)
    values (m.id, s.propose_par, s.jour, 'Suggestion supprimée pour le ' || _jour_fr(s.jour) || ' : ' || s.titre);
end $$;

create or replace function ajouter_membre(p_jeton uuid, p_prenom text, p_emoji text, p_couleur text, p_parent boolean)
returns text language plpgsql security definer set search_path = public as $$
declare m membres := _qui(p_jeton); nom text; id text;
begin
  if not m.parent then raise exception 'Seuls les parents peuvent ajouter un membre.'; end if;
  nom := trim(p_prenom);
  if nom = '' then raise exception 'Le prénom est obligatoire.'; end if;
  if p_couleur is null or p_couleur not in ('rose','bleu') then raise exception 'Couleur invalide.'; end if;
  id := lower(regexp_replace(nom, '[^a-z0-9]+', '-', 'g'));
  id := regexp_replace(id, '^-+|-+$', '', 'g');
  if id = '' then id := 'membre'; end if;
  if exists (select 1 from membres where id = id) then
    id := id || '-' || floor(random() * 1000)::int::text;
  end if;
  insert into membres (id, prenom, emoji, couleur, parent, priorite, ordre, aime, naime_pas, allergies, sujet_ntfy)
  values (id, nom, coalesce(nullif(trim(p_emoji), ''), '🙂'), p_couleur, coalesce(p_parent, false), 0,
          (select coalesce(max(ordre), 0) + 1 from membres), '', '{}', '{}', 'repas-' || replace(gen_random_uuid()::text, '-', ''));
  insert into journal (par, membre, texte) values (m.id, id, 'Membre ajouté : ' || nom);
  return id;
end $$;

create or replace function supprimer_membre(p_jeton uuid, p_membre text) returns void
language plpgsql security definer set search_path = public as $$
declare m membres := _qui(p_jeton); c membres;
begin
  if m.id not in ('nadine','marc') then raise exception 'Seule Nadine ou Marc peut supprimer un membre.'; end if;
  if p_membre = m.id then raise exception 'Tu ne peux pas te supprimer toi-même.'; end if;
  select * into c from membres where id = p_membre;
  if not found then raise exception 'Membre inconnu.'; end if;
  delete from sessions where membre = p_membre;
  delete from presences where membre = p_membre;
  update invites set invite_par = m.id where invite_par = p_membre;
  update suggestions set propose_par = m.id where propose_par = p_membre;
  update suggestions set choisi_par = null where choisi_par = p_membre;
  delete from journal where membre = p_membre or par = p_membre;
  delete from membres where id = p_membre;
  insert into journal (par, membre, texte) values (m.id, p_membre, 'Membre supprimé : ' || c.prenom);
end $$;

create or replace function enregistrer_profil(p_jeton uuid, p_membre text, p_emoji text, p_aime text, p_naime_pas text[], p_allergies text[])
returns void language plpgsql security definer set search_path = public as $$
declare m membres := _qui(p_jeton); c membres;
begin
  if m.id <> p_membre and not m.parent then raise exception 'Tu ne peux modifier que ton propre profil.'; end if;
  update membres set emoji = coalesce(nullif(trim(p_emoji), ''), emoji), aime = coalesce(p_aime, ''),
                     naime_pas = coalesce(p_naime_pas, '{}'), allergies = coalesce(p_allergies, '{}')
   where id = p_membre returning * into c;
  if not found then raise exception 'Membre inconnu.'; end if;
  insert into journal (par, membre, texte) values (m.id, p_membre, 'Profil de ' || c.prenom || ' mis à jour');
end $$;

create or replace function changer_nip(p_jeton uuid, p_nouveau text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m membres := _qui(p_jeton);
begin
  if p_nouveau is null or p_nouveau !~ '^[0-9]{4}$' then raise exception 'Le NIP doit contenir 4 chiffres.'; end if;
  update membres set pin_hash = crypt(p_nouveau, gen_salt('bf')) where id = m.id;
end $$;

create or replace function reinitialiser_nip(p_jeton uuid, p_membre text) returns void
language plpgsql security definer set search_path = public as $$
declare m membres := _qui(p_jeton); c membres;
begin
  if not m.parent then raise exception 'Seuls les parents peuvent réinitialiser un NIP.'; end if;
  update membres set pin_hash = null, echecs = 0, bloque_jusqua = null where id = p_membre returning * into c;
  if not found then raise exception 'Membre inconnu.'; end if;
  delete from sessions where membre = p_membre;
  insert into journal (par, membre, texte) values (m.id, p_membre, 'NIP de ' || c.prenom || ' réinitialisé');
end $$;

-- ---------------------------------------------------------------------
--  Rappel automatique (seulement aux personnes qui n'ont pas répondu)
-- ---------------------------------------------------------------------
create or replace function envoyer_rappels() returns void
language plpgsql security definer set search_path = public as $$
declare
  auj date := _aujourdhui();
  m membres;
  manque text[];
begin
  if extract(hour from _maintenant())::int <> _reglage('heure_rappel')::int then return; end if;
  for m in select * from membres order by ordre loop
    manque := '{}';
    if not exists (select 1 from presences where jour = auj and membre = m.id and souper is not null) then
      manque := array_append(manque, 'ton souper de ce soir');
    end if;
    if not exists (select 1 from presences where jour = auj + 1 and membre = m.id and lunch is not null) then
      manque := array_append(manque, 'ton lunch de demain');
    end if;
    if cardinality(manque) > 0 then
      perform _notifier(m.sujet_ntfy,
        '⏰ Repas : réponds avant ' || _reglage('heure_limite') || 'h',
        m.prenom || ', indique ' || array_to_string(manque, ' et ') || '. Sans réponse, tu seras considéré(e) absent(e).',
        'alarm_clock', 4);
    end if;
  end loop;
end $$;

-- Toutes les heures pile; la fonction n'envoie qu'à l'heure du rappel (heure du Québec,
-- donc correct à l'heure d'été comme à l'heure normale).
select cron.unschedule(jobid) from cron.job where jobname = 'rappels-repas';
select cron.schedule('rappels-repas', '0 * * * *', 'select public.envoyer_rappels()');

-- Ménage : sessions de plus d'un an et journal de plus de 6 mois
select cron.unschedule(jobid) from cron.job where jobname = 'menage-repas';
select cron.schedule('menage-repas', '30 3 * * 0',
  $$delete from public.sessions where cree < now() - interval '1 year';
    delete from public.journal where quand < now() - interval '6 months';$$);

-- ---------------------------------------------------------------------
--  Droits : l'app (rôle anon) n'appelle que les fonctions publiques
-- ---------------------------------------------------------------------
revoke execute on function _reglage(text), _maintenant(), _aujourdhui(), _heure_fr(timestamptz), _qui(uuid),
  _notifier(text, text, text, text, int), _choisir(membres, uuid), envoyer_rappels()
  from public, anon, authenticated;
revoke execute on function enregistrer_heure_souper(uuid, date, text) from public, authenticated;
grant execute on function list_membres(), connexion(text, text), deconnexion(uuid), donnees(uuid, date, date),
  ajouter_membre(uuid, text, text, text, boolean), supprimer_membre(uuid, text),
  enregistrer_heure_souper(uuid, date, text),
  enregistrer_presence(uuid, text, date, text, text), enregistrer_invite(uuid, uuid, date, text, text[], text[]),
  supprimer_invite(uuid, uuid), proposer_repas(uuid, date, text, text, boolean), choisir_repas(uuid, uuid),
  retirer_choix(uuid, date), supprimer_suggestion(uuid, uuid),
  enregistrer_profil(uuid, text, text, text, text[], text[]), changer_nip(uuid, text), reinitialiser_nip(uuid, text)
  to anon;

-- Affiche le sujet ntfy des parents (à noter)
select valeur as sujet_ntfy_des_parents from reglages where cle = 'sujet_parents';
