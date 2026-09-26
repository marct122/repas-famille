# Projet « Repas en famille » — consignes pour Claude

## Au début de CHAQUE conversation

Avant de répondre à la première demande de Marc :

1. Lis les fichiers du dossier `pour cowork/`, dans l'ordre : `00-LISEZ-MOI.md`, `01-PROMPT-DE-REPRISE.md`, puis `02` à `07` et `09`. Lis `08-SECRETS.md` **seulement** si la tâche l'exige.
2. Commence ta réponse par un **résumé de 3 lignes au maximum** : où en est le projet, et la prochaine étape prévue. Traite ensuite la demande de Marc.
3. Si le dossier `pour cowork/` est absent (par exemple dans une copie venant de GitHub), dis-le à Marc : il est volontairement exclu de GitHub.

## Règles permanentes (détails dans `pour cowork/`)

- Réponds en **français**. Marc apprend VS Code et Git pour son travail : agis en **professeur**. Donne des étapes qu'il fait lui-même, explique le pourquoi, puis vérifie son travail.
- **Explique ce que tu vas faire avant de modifier des fichiers.** Marc fait lui-même les **commits, les fusions et les push**.
- **Ne rien assumer** : pose une question dès qu'une décision appartient à Marc.
- L'app est **en production** pour la famille. La base Supabase **n'a pas de branches** : exécuter `supabase.sql` dans Supabase **avant** de pousser `main`.
- Toute nouvelle fonction SQL doit aussi exister dans le **mode démo** (objet `Demo` dans `index.html`). `supabase.sql` doit rester ré-exécutable.
- Tester `supabase.sql` avec `pour cowork/outils-test-sql/` avant de le faire exécuter en production.
- **Secrets :** seulement dans `pour cowork/08-SECRETS.md`. Ne jamais les copier ailleurs ; ne jamais retirer `pour cowork/` du `.gitignore`.
- **Mets à jour `pour cowork/`** (au minimum `04` et `05`) **après chaque étape importante**, comme le ferait Claude Cowork.
