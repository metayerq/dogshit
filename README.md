# Mapa do Cocó — Lisboa

Carte collaborative des déjections canines à Lisbonne. **Aucune photo, aucun nom, aucune personne signalée** — on cartographie le problème, pas les gens.

## Lancer en local

```bash
python3 -m http.server 4173
```

Puis ouvrir <http://localhost:4173>. Sans configuration, l'app tourne en **mode local** : les signalements restent dans le `localStorage` du navigateur.

## Passer en carte partagée (Supabase)

1. Créer un projet sur [supabase.com](https://supabase.com) (le plan gratuit suffit largement pour démarrer).
2. SQL Editor → coller et exécuter [`supabase/schema.sql`](supabase/schema.sql).
3. Project Settings → API → copier l'URL du projet et la clé `anon`.
4. Les renseigner en haut du `<script>` dans [`index.html`](index.html) :

```js
const SUPABASE_URL = "https://xxxx.supabase.co";
const SUPABASE_ANON_KEY = "eyJ...";
```

Le bandeau passe de « MODE LOCAL » à « MODE PARTAGÉ ». Le reste du code est identique : les deux modes implémentent la même interface (`list` / `add` / `clean` / `confirm`).

La clé `anon` est publique par conception — c'est la RLS qui protège les données. Le client anonyme peut **lire** ; il ne peut **écrire** que par les trois fonctions `security definer` (`create_report`, `mark_cleaned`, `confirm_still_there`), qui portent la validation bbox et l'anti-spam. Aucune policy `insert` / `update` / `delete` n'est accordée.

## Le modèle de données

**Rien n'est jamais supprimé, tout se périme.** Un signalement est un fait horodaté immuable ; ce qui change, c'est son poids à l'affichage.

- **Couche « live »** — décroissance exponentielle : `poids = 0.5 ^ (âge_heures / demi-vie)`. La demi-vie dépend de la freguesia (24 h en Baixa où le balayage est quotidien, 96 h à Marvila), paramétrable dans `freguesia_config`. Sous 0,05 (≈ 4 demi-vies) le point sort de l'affichage — sans jamais sortir de la base.
- **Couche « chronique »** — 30 jours / 6 mois, sans décroissance, nettoyés compris. C'est la mémoire longue : celle qui distingue un incident d'un problème structurel, et la seule qui ait une valeur politique face à la mairie.

Trois signaux font vivre un point : le **temps** (décroissance automatique), **« Nettoyé »** (poids à zéro, et le délai signalement → nettoyage est enregistré — un indicateur de performance du service public que personne d'autre ne produit), et **« Encore là »** (poids remis à fond + compteur de récidive).

`report_events` est un journal append-only : on peut rejouer tout l'historique.

## Anti-abus

Le jour où l'app marche, quelqu'un essaiera de noyer une rue qu'il n'aime pas. Côté serveur, dans `create_report` :

- rejet des coordonnées hors du municipe de Lisbonne ;
- 20 signalements/heure maximum par appareil ;
- rejet des doublons (même appareil, ~15 m, < 10 min).

`device_hash` est un UUID aléatoire généré côté client, jamais un identifiant réel.

## Limites connues

- **Freguesia par centroïde le plus proche**, pas par polygone : approximatif près des frontières (Arroios / Penha de França notamment). À remplacer par du point-in-polygon sur le GeoJSON officiel des freguesias avant toute communication publique des classements.
- Les demi-vies par freguesia sont des **estimations**, pas des fréquences de nettoyage vérifiées auprès de la CML.
- Le bouton « Charger des points de démo » génère des données **fictives**, marquées `is_demo` / `demo: true` dans l'export. Elles ne servent qu'à vérifier le rendu.

## Export

Le bouton « Exporter GeoJSON » produit un fichier ouvrable dans QGIS ou un tableur, avec pour chaque point : horodatage, freguesia, statut, délai de nettoyage en heures, nombre de récidives, poids actuel. C'est ce fichier qu'on joint à un courrier à la Câmara Municipal.
