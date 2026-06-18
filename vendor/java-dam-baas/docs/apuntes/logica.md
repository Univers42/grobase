1️⃣ Roles y tipos de usuario

¿Qué roles habrá exactamente?

- Solo habrá estos 3 roles en la aplicación.
☐ Administrador
☐ Cortador de jamón
☐ Usuario / Cliente

¿El admin es un usuario único predefinido, o puede haber múltiples admins? Solo hay un unico admin.

¿El administrador también puede:

- Puede crear usuarios normales y cortadores manualmente y gestionarlos a parte de gestionar también la app.
- El admin tiene capacidad completa sobretoda la app.

¿Los cortadores:

- Solo existen como recurso gestionado por el administrador. No existen como usuario activo de la app.
- Solo recibe notificaciones por email, que estara en su perfil como correo electronico.

Los usuarios pueden registrarse, y modificar sus datos y hacer/modificar o cancelar las reservas de sus pedidos.

¿Cómo se registra un usuario normal?
El registro es automatico, necesitara los datos:
dni, Nombre, apellidos, correoelectronico, telefono, y que esten validados los datos y se registrara automaticamente el usuario en la app. y podra empezar a utilizarla.

P5.3: ¿Los clientes pueden ver su historial de reservas pasadas?
Si no es muy dificil de implementar se podria hacer.

2️⃣ Gestión de cortadores y horarios

P9.1: ¿Tiempo mínimo entre reservas? 30 minutos paara asi ajustar los slots de 30 en 30 y el horarios fijo.

P9.2: ¿Máximo de servicios por día para un cortador?
3 jamones maximo. lo que seria equivalente a 6 horas de trabajo efectivo y asi en total para todo.

¿El horario del cortador es:

- Vamos a hacerlos fijo, ya que yo creo que meternos en un horario discontinuo subiria mucho la complejidad del proyecto. Podria ser una de las cosas a remarcar como en una version escalable del proyecto.

¿Puede haber varios cortadores trabajando a la vez en el mismo tramo horario?

- Si varios cortadores pueden compartir horario, de echo lo van a compartir, ya que hemos dicho que solicitaremos un horario fijo para hacerlo mas facil.

¿Mínimo 1 cortador: si no hay ninguno, ¿la app muestra un mensaje y bloquea todo, o permite al admin crear uno en runtime? Si minimo uno si no hay cortadores tanto a admins como usuarios le saldran las opciones de reserva desactivadas.

¿Los cortadores tienen atributos extra (e.g., nombre, experiencia, especialidad en jamón/paleta)? (Al menos 3 tablas: e.g., Cortadores, Horarios, Servicios; relaciones obligatorias, página 7). Si supongo que los cortadores igual necesitaran un nombre, apellido, dni y algun dato como experiencia y especialidad si no es muy complicado añadirlo.

3️⃣ Tipos de trabajo (servicios)

Cortador trabaja 10-18h (8 horas). Si hay servicio de 2h, ¿slots fijos de 2h (10-12, 12-14...) o puede empezar a cualquier hora (10:30, 11:15...)? Slots fijos!

¿Los tipos de trabajo son fijos?

- Si los horarios van a ser fijos, igual que los horarios de los cortadores son fijos estos tambien van a estar predefinidos

Corte de jamón → 2 horas
Corte de paleta → 1 hora
Corte de embutido → 30 min
Primero elegiremos el tipo de corte que necesitamos y luego se selecionara en la aplicación el tramo libre.

¿Cómo se calcula disponibilidad? ¿Bloqueo por slots exactos (e.g., reserva de 2h para jamón inicia en hora en punto), o flexible? Vamos a hacerlo por slots exactos.

¿El precio del servicio:

- Lo dejaremos fijado como un precio informativo nada mas, evitaremos complicarnos, Igual que los horarios esto podria entrar dentro de la escalabilidad de del proyecto a futuro.

¿Los 3 tipos (corte jamón 2h, paleta 1h, embutido 0.5h) son fijos, o el admin puede añadir/modificar tipos? ¿Incluyen precios o detalles (e.g., cantidad de jamón)? Van a ser cortes fijos y solo estos tres exactamente, La parte de añadir mas lo dejaremo igualmente como una version superior o el escalado de la aplicación.

¿Proceso de reserva: el usuario ve calendario por cortador/fecha, selecciona servicio y hora disponible? ¿Puede cancelar/modificar una reserva? Asi es, se mostrara el calendario con la disponibilidad segun el cortador elegido.

¿Qué pasa si hay solapamientos (e.g., reserva de 2h bloquea slots adyacentes)? ¿Notificaciones en app además de email? Habra que gestionar muy bien para que esto no pase, control de errores, evitar dataraces y bloqueos en la bbdd.

¿Se permite:

- Solo 1 trabajo por reserva, y maximo de 2 reservas diarias por cliente.

4️⃣ Reservas y calendario

Parte crítica para el análisis.

¿La reserva se hace:

- Por bloques automáticos según el tipo de corte

¿Qué pasa si: Un usuario intenta reservar fuera del horario, O en un hueco insuficiente para el tipo de trabajo?
-Deberiamos controlar este tipo de errores, que no se puedan solicitar reservas fuera de horario, o si ha seleccionado un trabajo de 2 horas y el cortador solo tiene una disponible de error.

- Se permite: Cancelar reservas, Modificarlas y crearlas. Tanto el admin como el usuario que haya realizado la reserva, podra hacer eso. Siempre con 1 dia de antelacion, por ejemplo si estoy en lunes 14 de enero, solo podre hacerlo desde el 15 de enero en adelante, y el administrador tambien tendra esa regla.

¿Hay límite de reservas por usuario?
- Si, 2 Por día y 4 Por semana

5️⃣ Estados de una reserva

¿Qué estados tendrá una reserva?

Pendiente, cuando se esta realizando la reserva o cuando se esta modificando.
Confirmada, cuando se ha seleccionado la reserva y ya tiene el cortador asignado y el horario.
Cancelada, cuando se ha cancelado.
Realizada, cuando ya ha pasado la fecha y se ha realizado.

¿Quién cambia el estado?
- Automáticamente el sistema

6️⃣ Correos electrónicos

Aquí hay que acotar para no complicarse.

¿El envío de emails será:

O simulado (registro en BD / log), creo qeu lo mas facil es simularlo en un log no?

¿Qué eventos envían email?

- Nueva reserva, Cancelación

¿El contenido del email será:

- Muy simple (texto plano)

7️⃣ Seguridad y acceso

Para requisitos no funcionales.

¿Habrá login con:

- Usuario + contraseña

Roles diferenciados

¿Se exige:

- Contraseña mínima
- Encriptación (BCrypt, por ejemplo)

¿Un usuario puede:

Ver solo sus reservas, para ver disponibilidad general deberia ir a otra parte para realizar sus reservas

Sobre Interfaz y Frontend (para diseño con mockups, 6-14 páginas)

¿Vistas principales en JavaFX: e.g., login, dashboard admin (CRUD cortadores), calendario usuario, confirmación reserva?
Si lo haremos con javafx

¿Elementos visuales: calendario interactivo? 
Si habra que ver un calendario interactivo o no se como podriamos representarlo para que sea aceptable visualmente si subir o elevar la dificultad ni el rendimiento de la app.

- Idioma solo español

- Requisitos no funcionales: app fija 

¿Manejo de errores (e.g., conexión BBDD fallida)? Si es muy importante el manejo de errores.


8️⃣ Alcance funcional (muy importante)

Informes o un pequeño log por si sale algun fallo no?

¿El objetivo es:

CRUD completo + reservas funcionales


9️⃣ Límites del proyecto (decisión estratégica)

Respóndeme honestamente:

¿Prefiero: Menos funcionalidades pero muy bien hechas

¿El foco principal debe ser:

Lógica de negocio

Arquitectura cliente-servidor

✅ Incluir SÍ o SÍ:

CRUD de Cortadores (Admin)
CRUD de Clientes (Registro + perfil)
Gestión de horarios semanales por cortador (tabla horaria L-V)
3 tipos de servicio fijos (sin cantidades)
Calendario de disponibilidad visual (JavaFX TableView/GridPane)
Sistema de reservas (Confirmada automáticamente)
Listado de reservas por cortador/cliente
Notificaciones INTERNAS (tabla "Notificaciones" en DB, sin email real)
Login con roles (Admin, Cortador, Cliente)
Bloqueo de app si 0 cortadores