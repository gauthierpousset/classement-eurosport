# Classement Eurosport — mise en ligne (≈ 30-45 min, gratuit)

Tu vas utiliser deux services gratuits : **Supabase** (la base de données) et **GitHub** (qui héberge le site).
Aucune carte bancaire n'est demandée.

## Contenu du kit
- `docs/` : l'application (index.html, config.js, manifest, sw.js, icônes)
- `supabase/schema.sql` : la base de données (à exécuter une fois)
- `.github/workflows/keepalive.yml` : garde la base éveillée

## 1. Créer la base (Supabase)
1. Va sur https://supabase.com, crée un compte (gratuit), puis **New project**. Choisis un nom, un mot de passe de base (note-le), la région la plus proche (ex. Paris/Francfort).
2. Attends la fin de la création, puis ouvre **SQL Editor** → **New query**.
3. Ouvre `supabase/schema.sql`, copie **tout** son contenu, colle-le dans l'éditeur, clique **Run**. Tu dois voir « Success ».
   (Tu peux relancer le script sans danger.)

## 2. Récupérer l'adresse et la clé
Dans Supabase : **Project Settings → API** (ou « Data API »). Note :
- **Project URL** (https://xxxx.supabase.co)
- la clé **anon / public** (ou « publishable »)

Ces deux valeurs sont publiques par conception. **Ne copie jamais** la clé « service_role » / « secret ».

## 3. Renseigner `docs/config.js`
Remplace les deux valeurs `COLLE_ICI…` par l'adresse et la clé, en gardant les guillemets simples.

## 4. Publier le site (GitHub Pages)
1. Crée un compte sur https://github.com, puis **New repository** (public, nom libre, ex. `classement`).
2. **Add file → Upload files** : envoie **le contenu du kit** (dossiers `docs`, `supabase`, `.github` et ce fichier). Astuce : le dossier `.github` est caché sur certains systèmes ; s'il manque, crée le fichier via **Add file → Create new file** avec le nom `.github/workflows/keepalive.yml` et colle son contenu.
3. **Settings → Pages** : Source = **Deploy from a branch**, branche `main`, dossier **/docs**, puis **Save**.
4. Après 1-2 minutes, l'adresse apparaît : `https://TON-PSEUDO.github.io/classement/`.

## 5. Vérifier
Ouvre l'adresse suivie de `?diagnostic` (ex. `…/classement/?diagnostic`). Chaque ligne doit être verte. Si une ligne est rouge, le message dit quoi corriger. Sinon, envoie-moi la capture.

## 6. Créer les gamemasters
1. Dans l'app, chacun (toi, ton frère, ton père) crée son compte : pseudo + code de 6 caractères minimum.
2. Dans Supabase, **SQL Editor**, exécute (adapte les pseudos) :
```sql
update public.accounts set role='gamemaster' where lower(pseudo) in ('gauthier','frere','pere');
```
3. Ensuite, un gamemaster peut nommer d'autres gamemasters depuis l'espace GM → « Joueurs et rôles ».
Code oublié : un gamemaster le réinitialise depuis cette même section.

## 7. Partager et installer
- Envoie l'adresse sur WhatsApp. Chacun s'inscrit, puis rejoint une ligue avec son code (ou en crée une).
- **iPhone** : ouvrir dans Safari → bouton Partager → « Sur l'écran d'accueil ».
- **Android** : Chrome → menu ⋮ → « Installer l'application » / « Ajouter à l'écran d'accueil ».

## 8. Garder la base éveillée
Supabase gratuit met le projet en pause après 7 jours sans activité. Le workflow `keepalive.yml` l'appelle tous les 2 jours. Onglet **Actions** du dépôt : active-le si GitHub le demande, puis « Run workflow » une fois pour tester.

## Vie du jeu
- **Date de clôture** (20 déc. 23h59 par défaut) : 
```sql
update public.seasons set closes_at = '2026-12-20 23:59:59+01' where id = (select max(id) from public.seasons);
```
- Les gamemasters saisissent chaque jour les athlètes révélés (Monde et France). Le rapprochement des orthographes n'est possible qu'après la clôture.
- **Nouvelle saison** : ajouter une ligne dans `seasons` (voir `schema.sql`) ; l'app utilise la plus récente.

## Limites et sauvegardes
Gratuit : 500 Mo de base (très largement suffisant). Pour sauvegarder : Supabase → Table Editor → export CSV des tables. 

## Données personnelles
L'app ne collecte qu'un pseudo et un code (stocké chiffré, jamais en clair). Mentions et suppression du compte sont dans le profil de l'app.

## Franchise
Ce kit a été testé sur une vraie base PostgreSQL (94 contrôles) et sur l'application avec une base simulée (39 + parité de calcul), **mais pas sur un vrai projet Supabase ni sur de vrais téléphones**. D'où la page `?diagnostic` : en cas de souci, envoie-moi son résultat.

## Dépannage
- Page blanche / « config » : `config.js` mal rempli.
- « Could not find the function » : `schema.sql` non exécuté en entier.
- Clé refusée : tu as peut-être collé la mauvaise clé.
- Site non mis à jour : vide le cache ou rouvre l'app.
