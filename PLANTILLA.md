# Lavadero · OrbePy

App para lavaderos de autos (`index.html`), publicada en **orbepy.com/lavadero/?club=&lt;id&gt;**.
Demostración sin datos reales: **orbepy.com/lavadero/?demo**.

## 1. Qué hacen los sistemas parecidos (investigación)

| Producto | Lo que tomamos |
|---|---|
| Washa (CRM para lavaderos) | Ficha de cliente + vehículos + historial de servicios en un solo lugar |
| Softhealer Vehicle Washing | Tablero por estados: en cola → lavando → listo → entregado |
| Anolla / Nautilus | Reconocer la chapa y autocompletar cliente, servicio y precio |
| LavaPro Admin | Panel del dueño con caja del día, rendimiento por empleado y varios locales |
| Swash / GetLavado | Aviso por WhatsApp y modelo SaaS con suscripción mensual |

Lo que **no** copiamos (para que sea simple): reservas online, membresías de lavado ilimitado, inventario de insumos y nómina. Son extras para más adelante.

### Aporte de ChatGPT (boceto "LavaPro", 03/10/2026)

Tomado: columnas del tablero teñidas por estado, chips de chapas recientes en el ingreso, filtros y "último pago" en el panel, contador de dados de baja.
Descartado: Montserrat + Inter (genéricas; se mantiene Barlow Condensed por legibilidad al sol), fotos en los servicios, avatares de empleados, barra de progreso del lavado (sería un dato inventado), escaneo de chapa por cámara (queda para más adelante).

### Marca: Black Wash by JM

Paleta tomada del logo: negro `#0E0E10` en barra y pantallas de ingreso, dorado `#E3B341` en acciones principales. Contenido en gris claro para leerse bien al sol. Estados: gris (espera), azul `#1E63C8` (lavando), verde (listo). Cada lavadero puede subir su logo en Administración → Ajustes.

## 2. Tres niveles de acceso

1. **Plataforma (José)**: el **panel Orbe** (orbepy.com/panel). Cada lavadero es un cliente con la aplicación *Lavadero de autos*: cuota, vencimiento, pagos, período de prueba, código de activación, suspender o dar de baja. El bloqueo por falta de pago es automático (vencimiento + días de gracia).
2. **Administrador del lavadero**: caja (hoy / 7 / 30 días), órdenes, clientes, servicios y precios por tipo de vehículo, personal con PIN, mensajes de WhatsApp y logo.
3. **Empleado**: solo **Nuevo ingreso** y **Tablero**. Entra con nombre + PIN de 4 números.

## 3. Flujo del empleado

```
Llega el auto → [Nuevo ingreso] chapa → (si es conocida se completa sola) → servicios → Registrar
Tablero: [Empezar] → [Está listo] → aviso de WhatsApp (retira / delivery) → [Cobrar] → Entregado
```

Reglas (las controla el servidor): una chapa no puede estar dos veces en el local; el precio sale de la lista de servicios y queda congelado en la orden; para anular hay que escribir el motivo; un doble toque no avanza dos pasos.

## 4. Cómo está armado

- **Base**: el mismo proyecto Supabase *orbe-clientes* del pádel y del panel. Migración: `supabase/012_lavadero.sql` (sigue la numeración 001–011 de cancha-padel).
- **Aislamiento entre clientes**: todas las tablas `lav_*` llevan `club_id` y seguridad por fila (`es_miembro`): un dispositivo solo ve su lavadero.
- **Acceso**: dispositivo activado una vez con el código del cliente (sesión anónima), personas con PIN y sesión con token (`operadores`, `verificar_pin`). Toda escritura pasa por funciones `lav_*` que verifican sesión, rol y que el cliente sea un lavadero.
- **Tablas**: `lav_config` (mensajes, logo, numerador), `lav_servicios` (precio auto / camioneta / moto), `lav_clientes`, `lav_vehiculos` (chapa única por lavadero), `lav_ordenes`.
- **Tiempo real**: canal `lav-<club>`; lo que carga la tablet aparece al instante en el celular del dueño.
- **Panel**: `panel_clientes` muestra autos y cobrado de los últimos 30 días para los lavaderos.
- **Pruebas** (03/10/2026, con un lavadero temporal en la base real, después borrado): 23 del circuito completo + 13 de seguridad, todas bien.

## 5. Para sumar un lavadero nuevo

1. En el panel: *Nuevo cliente* → aplicación **Lavadero de autos** → identificador (ej. `lavadero-centro`).
2. Ponerle un **código de activación**.
3. Pasar el enlace `orbepy.com/lavadero/?club=<identificador>` y el código. En la tablet se activa una vez, se crea el primer administrador y se cargan los servicios.

## 6. WhatsApp

- **Hoy**: un enlace `wa.me` con el mensaje armado. El empleado toca "Abrir WhatsApp" y "Enviar". No tiene costo y no hace falta aprobación de Meta.
- **Más adelante (automático)**: WhatsApp Business API (por ejemplo KAPSO, la misma de Academia DG) con plantillas aprobadas `vehiculo_listo_retiro` y `vehiculo_listo_delivery`. Se dispararía sola al tocar "Está listo".

## 7. Ideas para más adelante

- Enlace de seguimiento para el cliente con el estado del auto en vivo
- Foto del vehículo al ingresar (rayones previos)
- Membresía mensual de lavados para clientes frecuentes
- Cierre de caja por turno con arqueo de efectivo
- Factura electrónica (SIFEN)
- Historial de órdenes de más de 60 días en la app (hoy carga los últimos 60)
