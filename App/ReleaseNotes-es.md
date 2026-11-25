# Release notes

## [Unreleased]

## [0.5.0] - 2026-11-25

### Captura, grabación y edición en Studio más ágiles

- **Desplazamiento en 4 direcciones y temporizador flexible.** Captura con desplazamiento hacia abajo, arriba, izquierda o derecha con velocidad ajustable; cambia los segundos del temporizador en pantalla (`D` o `1`–`5`) y cancélalo con `Esc` o un clic.
- **Control de audio previo y durante la grabación.** Comprueba el nivel del micrófono en vivo antes de grabar, siléncialo o actívalo durante la grabación, pausa o activa Dibujar en pantalla desde la barra de menús y elige la frecuencia y el tamaño desde el menú emergente Crear GIF.
- **Forma de onda, volumen general, recorte y paquetes de Studio.** Visualiza la forma de onda del audio en la línea de tiempo, ajusta el volumen general con fundidos de entrada/salida y microfundidos en los cortes, recorta el vídeo de forma no destructiva, arrastra o redimensiona tramos de velocidad y cortes, controla la reproducción con `J`/`K`/`L`, haz zoom con pellizco en la línea de tiempo y exporta o importa paquetes independientes `.omsstudio`.

### Anotación, OCR y traducción mejorados

- **Flujo de marcado más rápido.** Haz doble clic en una herramienta para bloquearla, mantén Ocultar activo tras cada trazo, copia y pega marcas entre editores, toma colores del lienzo compuesto, elige entre Copiar y cerrar o Copiar sin cerrar (`⌘C`), ajusta el radio de esquinas y la intensidad de ocultación, y ejecuta Reconocer texto o Imprimir desde el editor.
- **Panel OCR ampliable, edición de tablas y cambio rápido de idioma.** Amplía y desplaza imágenes en el panel OCR, edita celdas de tablas y exporta en CSV o TSV (RFC-4180), configura delimitadores LaTeX para fórmulas, cambia el idioma de destino directamente en la lupa de traducción y copia, guarda o fija la imagen traducida.
- **Idiomas de OCR y espejos de modelos.** Configura idiomas preferidos de reconocimiento, activa o desactiva paquetes de modelos individualmente y añade un espejo de descarga personalizado en Ajustes.

### Historial, fijados, Acceso rápido y automatización

- **Más control en Historial, Fijados y Acceso rápido.** Selección múltiple con `⇧+Flecha`, filtros por fecha y app, uso de disco, deshacer Papelera durante 5 segundos y collages de varias columnas reordenables; tarjetas de Acceso rápido en las cuatro esquinas con cierre automático opcional; restauración de hasta 5 elementos fijados cerrados con sus transformaciones.
- **Más acciones en Atajos, esquema URL, Raycast y Compartir.** Nuevas acciones para anotar área, traducir área, selector de color, medir, dibujar en pantalla, guardar repetición y subir imagen (devolviendo la URL), junto con comandos de Raycast, Reconocer texto en el menú Compartir, cuatro nuevos atajos globales y gestión de apps bloqueadas.
- **Correcciones de código y fiabilidad.** Mejor eliminación de números de línea junto a márgenes estrechos y conservación de `//` en comentarios CJK, metadatos DPI Retina en PNG y limpieza conjunta de paquetes `.studio` al mover grabaciones a la Papelera.

## [0.4.0] - 2026-11-22

### Más formas de editar en Studio

- **Controla el ritmo y el sonido.** Cambia la velocidad de un tramo entre 0,5× y 4×, ajusta por separado el sonido del sistema y el micrófono, y dirige el zoom a un punto fijo en vez de seguir al puntero.
- **Cambia el fondo.** Desenfoca o quita el fondo de la cámara y coloca la grabación sobre una imagen o una copia desenfocada de sí misma. La exportación conserva el aspecto de la vista previa.
- **Exporta GIF y abre MP4 y MOV.** Exporta como GIF un proyecto editado en Studio, o abre un MP4 o MOV en la ventana de grabación para recortarlo o crear un GIF.

### Captura, anota y comparte

- **Lupa y Borrado.** Amplía un detalle hasta 4× o cubre una zona con los colores que la rodean. Los proyectos con estas marcas requieren OhMyShot 0.4.0 o posterior.
- **Fija y comparte sin salir.** Fija o sube una captura desde Anotar área; desde el editor también puedes compartirla. Las imágenes fijadas se pueden recuperar al volver a abrir la app.
- **Aprovecha el Historial de capturas.** Conserva los favoritos más allá del plazo habitual, arrastra o comparte varias capturas a la vez y copia texto desde el historial o Acceso rápido sin abrir el panel de reconocimiento.
- **Consulta las teclas al momento.** Pulsa ? al elegir un área o una ventana para ver sus teclas. En una pantalla congelada, pulsa B para ajustar el marco a su contenido.

### Ocultaciones y guardados más fiables

- **Lo que ocultas sigue oculto.** El desenfoque y el pixelado superpuestos usan las ocultaciones ya dibujadas, y los fondos desenfocados se crean con la captura ya ocultada. El editor, las exportaciones y las capturas compartidas respetan el mismo orden.
- **Conserva tu trabajo si falla el guardado.** Las anotaciones hechas en el área se pueden abrir en el editor aunque no se guarden en el historial. Los clips de repetición se conservan aunque no se puedan añadir al historial.

## [0.3.0] - 2026-11-21

### Todo en uno: elige una ventana y mide al momento

- **Haz clic en una ventana para capturarla.** Todo en uno resalta la ventana bajo el puntero y un clic la enmarca para cualquier tipo de captura. Arrastrar sigue eligiendo un área libre.
- **Mide desde la barra.** Pulsa M para medir sobre la pantalla congelada sin empezar de nuevo.
- **Un comienzo limpio.** Todo en uno se abre sin nada seleccionado, y L recupera la última área.

### Capturas con mejor acabado

- **Esquinas redondeadas y una sombra suave**, como iShot da a cada captura. Actívalas en Ajustes › Capturas de pantalla › Fondo.

### Texto leído tal como se ve

- **Las filas no se separan.** Capturar texto lee un listado de terminal, una lista de ajustes o una fila de una tabla como una sola línea, y reconoce las llaves en el código.
- **Pantallas ultrapanorámicas sin errores.** Una pantalla ultrapanorámica muy densa ya no pierde ni repite líneas.

### Tu trabajo, a salvo

- **Nada se pierde si algo falla.** Una captura que no se puede mover a la Papelera se queda en el Historial de capturas, al reemplazar una grabación se conserva la anterior hasta que la nueva está lista, y el editor sigue abierto hasta que se guardan los cambios.
- **Grabaciones que se detienen limpiamente.** Si el disco se llena o el archivo deja de poder escribirse, la grabación se detiene al instante e indica hasta qué momento se ha conservado. Studio conserva el borrador de una grabación hasta que todo esté guardado.
- **Ocultaciones más fuertes.** Desenfoque y Pixelado son más intensos en áreas grandes.

### Datos de uso

- **Datos de uso ahora está activado de forma predeterminada.** Solo envía los recuentos diarios de capturas de pantalla, grabaciones y reconocimientos de texto, con las versiones de la app y de macOS y un ID aleatorio que cambia cada día; nunca capturas, texto reconocido ni nombres de archivo. Desactívalo en Ajustes › General › Datos de uso, lo que también elimina los recuentos no enviados.

## [0.2.0] - 2026-11-19

### Siempre al día

- **Actualizaciones desde nuestra web.** La información de actualización y los archivos se descargan desde la web de OhMyShot, con GitHub como alternativa.
- **Avisos más visibles.** La nueva versión permanece al principio del menú y aparece una flecha junto al icono de la barra de menús. Puedes actualizar ahora o pedir un recordatorio para mañana.

### Una nueva ventana de novedades

- La ventana de **Novedades** se abre después de actualizar. Puedes leerla sin conexión.
- Las notas admiten títulos, listas, enlaces, énfasis y código en Markdown, además de un banner personalizado.

### Tú decides cuándo actualizar

- Se buscan actualizaciones al iniciar la app y cada seis horas. Las descargas y los reinicios siguen requiriendo tu confirmación.
