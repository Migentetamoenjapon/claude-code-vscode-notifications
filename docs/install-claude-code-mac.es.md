# Instala Claude Code en un Mac, desde cero

*[English](install-claude-code-mac.md)*

Esta guía es para quien nunca ha usado una terminal. Vas a instalar Claude Code, usarlo dentro de
VS Code y terminar instalando CCNotify, que muestra una ventanita cuando Claude termina o te necesita.

Toma unos 30 minutos. Ve en orden. Cada paso termina con una línea que te dice cuándo está listo.

## 0. La Terminal en 30 segundos

La Terminal es una ventana donde escribes comandos en lugar de hacer clic.

- **Ábrela:** presiona `⌘ Espacio`, escribe `Terminal` y presiona Enter.
- **Ejecuta un comando:** cópialo de esta página, haz clic en la ventana de la Terminal, pégalo con
  `⌘ V` y presiona Enter.
- **Contraseñas:** cuando la Terminal te pida la contraseña de tu Mac, no aparece nada mientras
  escribes. Ni puntos ni letras. Es normal. Escríbela y presiona Enter.

## 1. Una cuenta de Claude con plan de pago

Claude Code necesita un plan **Pro o Max**. El plan gratuito no lo incluye.

1. Entra a [claude.ai](https://claude.ai) y crea una cuenta.
2. Suscríbete a Pro o Max.

Consejo: usa **Sonnet** para el día a día. **Opus** es más potente, pero consume tu cuota más rápido.

## 2. Herramientas de línea de comandos de Apple

Traen `python3` y `git`, que necesitarás más adelante.

```bash
xcode-select --install
```

Se abre una ventana. Haz clic en **Instalar** y espera. Puede tardar varios minutos. Al terminar,
compruébalo:

```bash
python3 --version
```

**Listo cuando** muestre una versión como `Python 3.9.6`.

## 3. VS Code

1. Descarga VS Code desde [code.visualstudio.com](https://code.visualstudio.com).
2. Abre el archivo descargado y arrastra **Visual Studio Code** a la carpeta **Aplicaciones**.
3. Ábrelo desde Aplicaciones.

Opcional: para la interfaz en español, presiona `⇧⌘X`, busca "Spanish Language Pack", haz clic en
**Install** y reinicia VS Code cuando te lo pida.

**Listo cuando** el menú **Terminal → Nueva terminal** abra una terminal en la parte de abajo de la
ventana.

## 4. Claude Code

En la Terminal (o en la de VS Code), ejecuta:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Cierra la terminal y abre una nueva. Luego ejecuta:

```bash
claude
```

Se abre una pestaña del navegador. Inicia sesión con tu cuenta de Claude y aprueba la conexión.

**Listo cuando** este comando muestre un número de versión:

```bash
claude --version
```

### Si aparece «command not found»

1. Cierra por completo la Terminal y VS Code con `⌘ Q`, ábrelos de nuevo y vuelve a intentar.
2. Si no funciona, ejecuta esto:

   ```bash
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
   ```

   Si el prompt termina en `$` en lugar de `%`, usas bash. Usa `~/.bash_profile` en vez de `~/.zshrc`.

## 5. Tu primera conversación en VS Code

1. En VS Code, elige **Archivo → Abrir carpeta** y escoge una carpeta para tu proyecto (puedes crear
   una vacía).
2. Elige **Terminal → Nueva terminal**.
3. Escribe `claude` y presiona Enter.
4. Háblale en lenguaje normal, por ejemplo: «Crea una página web sencilla con mi nombre».

### Lo esencial

| Escribes o presionas | Qué hace |
|---|---|
| `/model` | Elige el modelo (Sonnet, Opus...). |
| `Esc` | Detiene lo que Claude está haciendo. |
| `/clear` | Empieza una conversación nueva. |
| `/exit` | Sale de Claude Code. |

### Permisos

Claude pregunta antes de crear archivos o ejecutar comandos. Lee lo que quiere hacer. Puedes permitirlo
una vez o para el resto de la sesión.

### Voz

Escribe `/voice tap`. La primera vez, macOS te pide acceso al micrófono para VS Code: permítelo.
Luego presiona `Espacio` para hablar y vuelve a presionarlo para terminar.

## 6. Git y GitHub (opcional)

Git guarda versiones de tu trabajo. GitHub las guarda en línea. Necesitas ambos para instalar este kit
desde su repositorio.

1. Crea una cuenta en [github.com](https://github.com).
2. Pídele a Claude:

   > Configura Git con mi nombre y correo, instala la herramienta gh de GitHub y ayúdame a iniciar sesión.

Mantén los datos personales fuera de tus repositorios (contraseñas, claves, datos de clientes). Prefiere
repositorios **privados**.

## 7. Instala CCNotify (este kit)

En la terminal de VS Code (no dentro de `claude`; escribe `/exit` primero si estás en él):

```bash
git clone https://github.com/Migentetamoenjapon/claude-code-vscode-notifications.git && cd claude-code-vscode-notifications && ./install.sh
```


El instalador compila las apps en tu Mac, así que tarda un minuto. Al terminar tendrás:

- **Una ventanita** arriba a la derecha cuando Claude termina o te necesita. Muestra el último mensaje
  de Claude. Haz clic en ella para saltar a la terminal correcta en VS Code.
- **Un ítem en la barra de menú** que lista cada sesión de Claude y su estado.
- **Sonidos** distintos según el tipo: terminó, permiso, pregunta, agente.

Inicia una conversación en `claude` y pídele algo pequeño. Cuando termine, aparecerá la ventanita.

Para ver las opciones (sonidos, horas de silencio, tamaño de la ventanita, la línea de estado),
consulta el [README](../README.md).

## Lo que no necesitas

- Python de python.org. Con el de las herramientas de línea de comandos basta.
- Node.js, para el instalador actual.
- Una clave de API de Anthropic. Inicias sesión con tu cuenta de Claude.
- La app de escritorio de Claude.

## Si algo falla

Copia el mensaje de error exacto de la Terminal y pégaselo a Claude, en una conversación o en el panel
de Claude. Cuéntale qué estabas haciendo cuando ocurrió. Casi siempre puede resolverlo.
