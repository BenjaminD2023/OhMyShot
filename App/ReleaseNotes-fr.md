# Release notes

## [Unreleased]

## [0.5.0] - 2026-11-25

### Capture, enregistrement et montage Studio plus fluides

- **Défilement dans 4 directions et retardateur souple.** Faites défiler vers le bas, le haut, la gauche ou la droite à vitesse réglable ; modifiez le délai du retardateur directement à l’écran (`D` ou `1`–`5`) et annulez le décompte avec `Échap` ou un clic.
- **Contrôle du micro avant et pendant l’enregistrement.** Vérifiez le niveau du micro en direct avant d’enregistrer, coupez ou réactivez le micro en cours d’enregistrement, mettez en pause ou activez Dessiner sur l’écran depuis la barre des menus, et choisissez la cadence et la taille dans la fenêtre Créer un GIF.
- **Forme d’onde, volume général, recadrage et paquets Studio.** Affichez la forme d’onde audio sur la timeline, réglez le volume général avec fondus d’entrée/sortie et micro-fondus aux coupes, recadrez la vidéo de façon non destructive, déplacez ou redimensionnez les sections de vitesse et de coupe, naviguez avec `J`/`K`/`L`, pincez pour zoomer sur la timeline et exportez ou importez des paquets autonomes `.omsstudio`.

### Annotation, OCR et traduction enrichis

- **Annotation et copie plus rapides.** Double-cliquez sur un outil pour le verrouiller, gardez Masquer en main entre plusieurs tracés, copiez-collez des marques entre éditeurs, prélevez des couleurs sur le rendu composite, choisissez Copier et fermer ou Copier sans fermer (`⌘C`), ajustez le rayon des coins et la force du masquage, et lancez Reconnaître le texte ou Imprimer depuis l’éditeur.
- **Panneau OCR zoomable, édition de tableaux et changement de langue rapide.** Zoomez et déplacez l’image dans le panneau OCR, modifiez les cellules de tableau sur place avec export CSV/TSV (RFC-4180), personnalisez les délimiteurs LaTeX des formules, changez la langue cible directement dans la loupe de traduction, et copiez, enregistrez ou épinglez l’image traduite.
- **Langues OCR et miroirs de modèles.** Choisissez les langues de reconnaissance préférées, activez ou désactivez chaque pack de modèles séparément et définissez un miroir de téléchargement personnalisé dans Réglages.

### Historique, épingles, Accès rapide et automatisation

- **Outils avancés pour l’Historique, les épingles et l’Accès rapide.** Sélection multiple avec `⇧+Flèches`, filtres par date et app, espace disque affiché, annulation de la Corbeille pendant 5 secondes et collages multi-colonnes réorganisables ; cartes d’Accès rapide dans les quatre coins avec fermeture automatique en option ; restauration jusqu’à 5 épingles fermées avec leurs transformations.
- **Raccourcis, schéma URL, Raycast et menu Partager étendus.** Nouvelles actions pour annoter ou traduire une zone, prélever une couleur, mesurer, dessiner sur l’écran, enregistrer le replay et envoyer une image (avec lien renvoyé), commandes Raycast associées, Reconnaître le texte dans le menu Partager, quatre nouveaux raccourcis globaux et gestion des apps refusées.
- **Reconnaissance de code et fiabilité.** Suppression plus fiable des numéros de ligne sur gouttière étroite et préservation de `//` dans les commentaires chinois/japonais, métadonnées DPI Retina dans les PNG et suppression conjointe du paquet `.studio` lors de la mise à la Corbeille.

## [0.4.0] - 2026-11-22

### Plus de possibilités de montage dans Studio

- **Réglez le rythme et le son.** Modifiez la vitesse d’un passage de 0,5× à 4×, ajustez séparément le son du système et celui du micro, et cadrez le zoom sur un point fixe plutôt que de suivre le pointeur.
- **Changez l’arrière-plan.** Floutez ou retirez l’arrière-plan de la caméra et placez l’enregistrement sur une image ou sur une copie floutée de lui-même. L’export conserve le rendu de l’aperçu.
- **Exportez en GIF, ouvrez les MP4 et MOV.** Exportez en GIF un projet monté dans Studio ou ouvrez un MP4 ou un MOV dans la fenêtre d’enregistrement pour le rogner ou créer un GIF.

### Capturer, annoter et partager

- **Loupe et Effacer.** Agrandissez un détail jusqu’à 4× ou recouvrez une zone avec les couleurs qui l’entourent. Les projets utilisant ces marques nécessitent OhMyShot 0.4.0 ou une version ultérieure.
- **Épinglez et partagez sans quitter votre travail.** Épinglez ou envoyez la capture depuis Annoter une zone. Vous pouvez aussi la partager depuis l’éditeur. Les épingles peuvent réapparaître à la réouverture de l’app.
- **Profitez de l’Historique des captures.** Conservez vos favoris au-delà de la durée habituelle, faites glisser ou partagez plusieurs captures à la fois et copiez du texte depuis l’historique ou Accès rapide sans ouvrir le panneau de reconnaissance.
- **Retrouvez les raccourcis sur place.** Appuyez sur ? en sélectionnant une zone ou une fenêtre pour afficher ses touches. Sur l’écran figé, B ajuste le cadre à ce qu’il contient.

### Masquage et sauvegarde plus fiables

- **Ce qui est masqué le reste.** Les flous et les pixellisations superposés utilisent les masquages déjà tracés. Les arrière-plans floutés partent eux aussi de la capture masquée. L’éditeur, les exports et le partage respectent le même ordre.
- **Gardez votre travail si la sauvegarde échoue.** Les annotations faites sur place peuvent toujours s’ouvrir dans l’éditeur si l’historique ne peut pas les enregistrer. Les extraits du replay sont conservés même si l’historique ne peut pas les ajouter.

## [0.3.0] - 2026-11-21

### Tout-en-un : choisissez une fenêtre, mesurez sur place

- **Cliquez sur une fenêtre pour la capturer.** Tout-en-un met en évidence la fenêtre sous le pointeur, et un clic la cadre pour tout type de capture. Un glisser choisit toujours une zone libre.
- **Mesurez depuis la barre.** Appuyez sur M pour mesurer sur l’écran figé sans tout recommencer.
- **Un départ vierge.** Tout-en-un s’ouvre sans rien sélectionner, et L rappelle la dernière zone.

### Des captures soignées

- **Coins arrondis et ombre douce**, comme iShot les donne à chaque capture. Activez-les dans Réglages › Captures d’écran › Arrière-plan.

### Un texte lu tel qu’il apparaît

- **Les lignes restent entières.** Capturer du texte lit une liste de terminal, une liste de réglages ou une ligne de tableau comme une seule ligne, et reconnaît les accolades dans le code.
- **Les écrans ultralarges bien lus.** Un écran ultralarge très dense ne perd ni ne répète plus de lignes.

### Votre travail en sécurité

- **Rien ne se perd en cas d’échec.** Une capture qui ne peut pas aller à la Corbeille reste dans l’Historique des captures, remplacer un enregistrement garde l’ancien jusqu’à ce que le nouveau soit en place, et l’éditeur reste ouvert jusqu’à ce que les modifications soient enregistrées.
- **Des enregistrements qui s’arrêtent proprement.** Quand le disque est plein ou que le fichier ne peut plus être écrit, l’enregistrement s’arrête aussitôt et indique jusqu’où il a été conservé. Studio garde le brouillon d’un enregistrement jusqu’à ce que tout soit enregistré.
- **Des masquages plus efficaces.** Flou et Pixeliser sont plus forts sur les grandes zones.

### Données d’utilisation

- **Les Données d’utilisation sont désormais activées par défaut.** Seuls sont envoyés les nombres quotidiens de captures d’écran, d’enregistrements et de reconnaissances de texte, avec les versions de l’app et de macOS et un identifiant aléatoire qui change chaque jour ; jamais de captures, de texte reconnu ni de noms de fichiers. Désactivez-les dans Réglages › Général › Données d’utilisation, ce qui supprime aussi les nombres non envoyés.

## [0.2.0] - 2026-11-19

### Restez à jour

- **Des mises à jour depuis notre site.** Les informations de mise à jour et les fichiers sont transmis par le site d’OhMyShot, avec GitHub en secours.
- **Des rappels bien visibles.** La nouvelle version reste en tête du menu et une flèche apparaît à côté de l’icône de la barre des menus. Mettez à jour maintenant ou demandez un rappel pour demain.

### Une nouvelle fenêtre de nouveautés

- La fenêtre **Nouveautés** s’ouvre après la mise à jour. Son contenu reste accessible hors ligne.
- Les notes prennent en charge les titres, listes, liens, mises en valeur et blocs de code Markdown, ainsi qu’une bannière personnalisée.

### Choisissez quand mettre à jour

- Les mises à jour sont recherchées au lancement et toutes les six heures. Le téléchargement et le redémarrage nécessitent toujours votre accord.
