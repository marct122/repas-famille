# Repas en famille — guide d'installation

Tout est gratuit : **Supabase** (base de données + rappels automatiques), **GitHub Pages** (l'adresse web de l'app) et **ntfy** (notifications push sur iPhone et Android).

Temps prévu : environ 30 minutes, une seule fois.

---

## 0. Essayer tout de suite (mode démo)

Double-clique sur `index.html`. Tant que `config.js` est vide, l'app fonctionne en **mode démo** : les données restent seulement sur l'ordinateur ou le téléphone utilisé, et les notifications s'affichent à l'écran.

---

## 1. Créer la base de données (Supabase)

1. Va sur <https://supabase.com> → **Start your project** → crée un compte (courriel ou GitHub).
2. **New project**
   - Name : `repas-famille`
   - Database password : invente-en un et garde-le.
   - Region : **Canada (Central)**
   - Plan : **Free**
3. Attends 1 à 2 minutes que le projet soit prêt.
4. Menu de gauche : **SQL Editor** → **New query**. Ouvre le fichier `supabase.sql` avec le Bloc-notes, copie **tout** le contenu, colle-le, puis clique **Run**.
5. En bas, un résultat affiche `sujet_ntfy_des_parents` (ex. `repas-parents-3f9a…`). **Note-le.** Il est aussi visible dans l'onglet **Moi** de l'app pour Nadine et toi.

> Si tu vois une erreur à propos de `pg_cron` ou `pg_net` : menu **Database → Extensions**, active **pg_cron** et **pg_net**, puis relance l'étape 4.

## 2. Relier l'app à la base de données

1. Dans Supabase : **Project Settings** (roue dentelée) → **API Keys**. Selon la version de Supabase, c'est aussi possible sous **Data API**.
2. Copie :
   - le **Project URL** (ex. `https://abcdefgh.supabase.co`) ;
   - la clé **publishable** (commence par `sb_publishable_…`). Si tu ne la vois pas, prends la clé **anon public**.
3. Ouvre `config.js` avec le Bloc-notes et colle les deux valeurs entre les apostrophes :

```js
window.CONFIG = {
  supabaseUrl: 'https://abcdefgh.supabase.co',
  supabaseKey: 'sb_publishable_xxxxxxxx'
};
```

> Cette clé peut être publique sans danger. Les tables sont fermées : toutes les actions passent par des fonctions qui exigent une connexion par NIP.

## 3. Mettre l'app en ligne (GitHub Pages)

1. Crée un compte sur <https://github.com>.
2. **New repository** → nom : `repas-famille` → **Public** → **Create repository**.
3. Clique **uploading an existing file**, puis glisse ces fichiers : `index.html`, `config.js`, `manifest.json`, `icone.svg`, `icone-180.png`, `icone-192.png`, `icone-512.png` → **Commit changes**.
   - N'envoie **pas** `supabase.sql` ni ce guide : ce n'est pas nécessaire.
4. **Settings** → **Pages** → Source : **Deploy from a branch** → Branch : `main`, dossier `/ (root)` → **Save**.
5. Après environ 1 minute, l'adresse de l'app apparaît : `https://TON-NOM.github.io/repas-famille/`.

**Optionnel :** pour qu'un toucher sur une notification ouvre l'app, exécute ceci dans **SQL Editor** (avec ta vraie adresse) :

```sql
update reglages set valeur = 'https://TON-NOM.github.io/repas-famille/' where cle = 'url_app';
```

## 4. Installer sur les téléphones (chaque membre)

1. Ouvre l'adresse de l'app.
   - **iPhone :** dans Safari, bouton **Partager** → **Sur l'écran d'accueil**.
   - **Android :** dans Chrome, menu **⋮** → **Ajouter à l'écran d'accueil**.
2. Touche son prénom et choisis un **NIP à 4 chiffres**. Le téléphone s'en souvient ensuite.
   - Chacun devrait le faire rapidement : tant qu'un profil n'a pas de NIP, n'importe qui peut en choisir un.
3. Installe l'app **ntfy** (App Store ou Google Play), touche **+**, puis colle son **sujet personnel** (onglet **Moi** → 📋 Copier).
4. **Nadine et Marc seulement :** abonnez-vous aussi au **sujet des parents**, pour les alertes d'annulation.

---

## Fonctionnement

| Règle | Détail |
|---|---|
| Limite de réponse | **11h** pour le souper du soir même **et** le lunch du lendemain |
| Sans réponse après 11h | absent au souper / pas de lunch |
| Après 11h | on peut encore s'ajouter ou annuler ; l'heure du changement est affichée (⏰) |
| Lunch | 🥪 froid = à l'école · 🍲 chaud = à la maison |
| Rappel à 10h | notification envoyée **seulement** à ceux qui n'ont pas répondu |
| Annulation | notification aux parents quand une présence confirmée (souper ou lunch) est annulée |
| Repas | tout le monde suggère ; Nadine ou Marc choisissent. Si les deux choisissent, **le choix de Nadine l'emporte** |
| Planification | on peut répondre et fixer les repas plusieurs jours d'avance (onglet Semaine / Repas) |
| Invités | tout le monde peut en ajouter (nom, allergies, n'aime pas) ; on voit qui a invité |
| Profils | modifiables par la personne elle-même et par les parents |
| 🚩 / ⚠️ | 🚩 = risque de ne pas aimer · ⚠️ = allergie. L'app compare le repas et ses ingrédients aux profils des personnes présentes |
| NIP oublié | un parent le réinitialise (onglet Famille) ; la personne en choisit un nouveau |

### Changer un réglage (SQL Editor)

```sql
update reglages set valeur = '9'  where cle = 'heure_rappel';  -- rappel à 9h
update reglages set valeur = '11' where cle = 'heure_limite';  -- heure limite
update membres set pin_hash = null where id = 'marc';          -- si les deux parents oublient leur NIP
```

### Modifier l'app plus tard

- **Interface :** modifie `index.html`, puis téléverse-le à nouveau sur GitHub (**Add file → Upload files**, il remplace l'ancien).
- **Base de données :** `supabase.sql` peut être relancé sans perdre les données.

### À savoir

- Un projet Supabase gratuit se met en pause après **7 jours sans utilisation**. Un usage quotidien suffit à l'éviter. S'il est en pause, clique **Restore** dans Supabase.
- Les sujets ntfy sont comme des mots de passe : quiconque les connaît peut lire les notifications. Ne les partage pas en dehors de la famille.
