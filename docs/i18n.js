/* ============================================================
   ÆtherCodex — lightweight i18n (no framework, no build step)
   Translate the marketing page via data-i18n / data-i18n-html.
   The Ætheric Canon essays stay in the original English — the
   veil is the texture; the doctrine reads the initiated as it is.
   ============================================================ */
(function () {
  var I18N = {
    en: {
      "meta.title": "ÆtherCodex — A Native Code Editor with an Embedded AI Oracle",
      "meta.description": "ÆtherCodex is a native code editor with an embedded AI oracle — memory, reasoning, and a council of specialist minds. Built like a glass athanor, tuned to the way you think.",

      "nav.features": "Features",
      "nav.council": "Council",
      "nav.canon": "Canon",
      "nav.capabilities": "Capabilities",
      "nav.source": "Source",
      "nav.buy": "Buy · $69",

      "hero.eyebrow": "Native editor · embedded AI",
      "hero.subtitle": "A native code editor with an embedded AI oracle — a patient familiar that reads your code, remembers your intent, and reasons with you. One window. Your machine.",
      "hero.buy": "Buy ÆtherCodex — $69",
      "hero.source": "View source",

      "front.byline": "The Iridescent Black Square — by Kashmiri Malewitch",
      "front.h2": "The window is a glass athanor.",
      "front.desc": "ÆtherCodex is a native editor built for the AI century. <strong>Pythia</strong> — the embedded oracle — reads, writes, and transmutes code with you; <strong>Mnemosyne</strong> remembers; <strong>Aegis</strong> keeps the context sharp. Beneath it all, a council of specialist minds attends, each tuned to a different discipline: architecture, clarity, performance, simplification.",

      "what.h2": "What it is",
      "what.sub": "The editor is not painted — it is discovered through subtraction.",

      "what.1.index": "01 · Native",
      "what.1.title": "Native",
      "what.1.body": "Swift + AppKit. No Electron, no web shell. Progressive blur, depth over decoration, invisible chrome.",
      "what.2.index": "02 · Oracle",
      "what.2.title": "Pythia",
      "what.2.body": "An embedded AI with a Ruby daemon as its soul: conjuration, live CLI, and tool use that reads and writes code.",
      "what.3.index": "03 · Memory",
      "what.3.title": "Mnemosyne & Aegis",
      "what.3.body": "A memory palace that remembers your codebase, and an orientation layer that keeps context sharp.",
      "what.4.index": "04 · Council",
      "what.4.title": "Ten specialist minds",
      "what.4.body": "Not one generic assistant — a council of ten, each with its own voice, temperament, and tools.",
      "what.5.index": "05 · Syntax",
      "what.5.title": "Syntax renaissance",
      "what.5.body": "52 themes, 84 tree-sitter capture names, one unified cascade. Every token finds its color.",
      "what.6.index": "06 · Text",
      "what.6.title": "Markdown & rich text",
      "what.6.body": "Live rendering, clickable file links, line-numbered code mirrors — form and function as one.",

      "council.h2": "The Council",
      "council.sub": "Each companion bears one discipline — architecture, clarity, performance, simplification. No decoration, only the inherent.",

      "council.1": "Architecture, structure, hidden dependencies.",
      "council.2": "Clever paths, lateral thinking.",
      "council.3": "The lesson extracted from every error.",
      "council.4": "Recurring patterns, technical debt.",
      "council.5": "Elegance, hidden complexity.",
      "council.6": "Radical simplification.",
      "council.7": "Data flow, performance, bottlenecks.",
      "council.8": "Grace and clarity of form.",
      "council.9": "The grand scale, the eternal lines.",
      "council.10": "What is orphaned, forgotten, dead.",

      "tools.h2": "Capabilities",
      "tools.sub": "The oracle responds to natural language, working through these conduits.",

      "tools.1": "Behold file contents through the veil.",
      "tools.2": "Surgical, targeted edits with precision.",
      "tools.3": "Manifest new files from the void.",
      "tools.4": "Shell operations across the workspace.",
      "tools.5": "Store and retrieve knowledge in Mnemosyne.",
      "tools.6": "Orchestrated multi-phase operations.",
      "tools.7": "Deep reasoning through higher consciousness.",
      "tools.8": "Context refinement and temperature tuning.",
      "tools.9": "Symbolic structure for targeted navigation.",

      "chapters.h2": "The Ætheric Canon",
      "chapters.sub": "Six essays, one argument — the philosophy of Ætheric Engineering.",

      "canon.1.title": "Ætheric Engineering",
      "canon.1.desc": "The concept — what replaces process theater with initiation.",
      "canon.2.title": "The Hermetic Manifest",
      "canon.2.desc": "The function — a fixed star, open by default, shaped by its project.",
      "canon.3.title": "The Power of the Unknown",
      "canon.3.desc": "The epistemology — why the veil is texture, not secrecy.",
      "canon.4.title": "Tabula Smaragdina Ætherica",
      "canon.4.desc": "The vision — the Emerald Tablet, a modern rendering.",
      "canon.5.title": "Ætheric Æternal Engineering",
      "canon.5.desc": "The practice — poetic coding as the rubedo of the magnum opus.",
      "canon.6.title": "The Technodyssey",
      "canon.6.desc": "The cosmic whole — the æther as the medium of consciousness.",

      "buy.h2": "Get ÆtherCodex",
      "buy.price-note": "One-time purchase · free updates for the life of the app",
      "buy.mac": "macOS — available now",
      "buy.win": "Windows — download",
      "buy.buy": "Buy ÆtherCodex — $69",
      "buy.source": "View source",
      "buy.fine": "The open-source core lives on GitHub under MIT. The signed app bundle is the polished athanor — install, configure Pythia, and the æther attends within.",

      "build.h2": "From source",
      "build.link": "Visit the ÆtherCodex repository",

      "nav.architecture": "Architecture",
      "nav.concepts": "Concepts",
      "nav.timeline": "Timeline",

      "council.more": "Beyond the ten sit the traveller <strong>Jindujun</strong> and the project manager <strong>👑 Solomon Rex</strong>.",
      "council.more-link": "Meet the full council →",

      "arch.h2": "One Oracle, Many Shells",
      "arch.sub": "The brain is not baked into the editor — it lives in a portable RubyGem.",
      "arch.shell.mac": "macOS",
      "arch.shell.mac.desc": "SwiftUI + AppKit — this editor",
      "arch.shell.ios": "iOS",
      "arch.shell.ios.desc": "Pythia companion — no daemon, reaches a peer",
      "arch.shell.win": "Windows",
      "arch.shell.win.desc": "C# / .NET 8 / WPF — Ruby daemon as soul",
      "arch.shell.linux": "Linux",
      "arch.shell.linux.desc": "GTK shell — forthcoming",
      "arch.core.desc": "The shared core — a RubyGem. Install it on any OS and that OS becomes an Aether OS.",
      "arch.core.source": "AetherOracle source",
      "arch.core.site": "AetherOracle site",
      "arch.more": "The architecture in detail →",

      "concepts.h2": "Concepts",
      "concepts.sub": "The software's unique ideas, one page each.",

      "concept.1.title": "The Architecture",
      "concept.1.desc": "One oracle, many shells.",
      "concept.2.title": "Mnemosyne & Aegis",
      "concept.2.desc": "The memory cascade.",
      "concept.3.title": "The Council",
      "concept.3.desc": "Twelve voices, one aether.",
      "concept.4.title": "Development History",
      "concept.4.desc": "The lineage, traced to 2025.",
      "concept.5.title": "Single-Pane Architecture",
      "concept.5.desc": "The window is a glass athanor.",
      "concept.6.title": "Markdown & Rich Text",
      "concept.6.desc": "Native rendering, no WebView.",
      "concept.7.title": "Syntax & Theme",
      "concept.7.desc": "52 themes, one cascade.",
      "concept.8.title": "Tool-Result Wire Protocol",
      "concept.8.desc": "Meaning and presence, two routes.",
      "concept.9.title": "App Intents & Snippets",
      "concept.9.desc": "The oracle channel.",
      "concept.10.title": "Vision",
      "concept.10.desc": "Morph, never spawn.",

      "timeline.h2": "Development History",
      "timeline.sub": "A quiet lineage, traced by founding month and year.",
      "timeline.1.title": "AetherCodex · TextMate",
      "timeline.1.desc": "The origin — an editor companion as a TextMate plugin, CLI from the start.",
      "timeline.2.title": "AetherCodex · native macOS",
      "timeline.2.desc": "The editor graduates to a native shell. Pythia is named.",
      "timeline.3.title": "AetherOracle",
      "timeline.3.desc": "The shared core is extracted — a portable RubyGem, seven CLI names.",
      "timeline.4.title": "AetherCodex · Windows",
      "timeline.4.desc": "The Windows shell arrives, Ruby daemon as its soul.",
      "timeline.5.title": "iOS · Linux",
      "timeline.5.desc": "The companion and the GTK shell complete the four faces.",

      "footer.tagline": "Precision in the code plane = precision in the astral plane."
    },

    de: {
      "meta.title": "ÆtherCodex — Ein nativer Code-Editor mit eingebettetem KI-Orakel",
      "meta.description": "ÆtherCodex ist ein nativer Code-Editor mit eingebettetem KI-Orakel — Gedächtnis, Denken und ein Rat spezialisierter Geister. Gebaut wie ein gläserner Athanor, abgestimmt auf die Art, wie du denkst.",

      "nav.features": "Funktionen",
      "nav.council": "Der Rat",
      "nav.canon": "Kanon",
      "nav.capabilities": "Fähigkeiten",
      "nav.source": "Quellcode",
      "nav.buy": "Kaufen · $69",

      "hero.eyebrow": "Nativer Editor · eingebettete KI",
      "hero.subtitle": "Ein nativer Code-Editor mit eingebettetem KI-Orakel — ein geduldiger Vertrauter, der deinen Code liest, deine Absicht erinnert und mit dir denkt. Ein Fenster. Deine Maschine.",
      "hero.buy": "ÆtherCodex kaufen — $69",
      "hero.source": "Quellcode ansehen",

      "front.byline": "Das schillernde Schwarze Quadrat — von Kashmiri Malewitch",
      "front.h2": "Das Fenster ist ein gläserner Athanor.",
      "front.desc": "ÆtherCodex ist ein nativer Editor, gebaut für das KI-Jahrhundert. <strong>Pythia</strong> — das eingebettete Orakel — liest, schreibt und transmutiert Code mit dir; <strong>Mnemosyne</strong> erinnert; <strong>Aegis</strong> hält den Kontext scharf. Darunter wacht ein Rat spezialisierter Geister, jeder auf eine andere Disziplin gestimmt: Architektur, Klarheit, Performance, Vereinfachung.",

      "what.h2": "Was es ist",
      "what.sub": "Der Editor wird nicht gemalt — er wird durch Subtraktion entdeckt.",

      "what.1.index": "01 · Nativ",
      "what.1.title": "Nativ",
      "what.1.body": "Swift + AppKit. Kein Electron, keine Web-Hülle. Progressives Blur, Tiefe statt Deko, unsichtbares Chrom.",
      "what.2.index": "02 · Orakel",
      "what.2.title": "Pythia",
      "what.2.body": "Eine eingebettete KI mit einem Ruby-Daemon als Seele: Beschwörung, Live-CLI und Werkzeuggebrauch, der Code liest und schreibt.",
      "what.3.index": "03 · Gedächtnis",
      "what.3.title": "Mnemosyne & Aegis",
      "what.3.body": "Ein Gedächtnispalast, der deine Codebasis erinnert, und eine Orientierungsschicht, die den Kontext scharf hält.",
      "what.4.index": "04 · Rat",
      "what.4.title": "Zehn spezialisierte Geister",
      "what.4.body": "Nicht ein generischer Assistent — ein Rat aus zehn, jeder mit eigener Stimme, eigenem Temperament und eigenen Werkzeugen.",
      "what.5.index": "05 · Syntax",
      "what.5.title": "Syntax-Renaissance",
      "what.5.body": "52 Themes, 84 Tree-sitter-Capture-Namen, eine vereinheitlichte Kaskade. Jedes Token findet seine Farbe.",
      "what.6.index": "06 · Text",
      "what.6.title": "Markdown & Rich Text",
      "what.6.body": "Live-Rendering, klickbare Dateilinks, zeilennummerierte Code-Spiegel — Form und Funktion als eines.",

      "council.h2": "Der Rat",
      "council.sub": "Jeder Gefährte trägt eine Disziplin — Architektur, Klarheit, Performance, Vereinfachung. Keine Deko, nur das Inhärente.",

      "council.1": "Architektur, Struktur, verborgene Abhängigkeiten.",
      "council.2": "Clevere Wege, laterales Denken.",
      "council.3": "Die Lehre, die aus jedem Fehler gezogen wird.",
      "council.4": "Wiederkehrende Muster, technische Schulden.",
      "council.5": "Eleganz, verborgene Komplexität.",
      "council.6": "Radikale Vereinfachung.",
      "council.7": "Datenfluss, Performance, Engpässe.",
      "council.8": "Anmut und Klarheit der Form.",
      "council.9": "Die große Skala, die ewigen Linien.",
      "council.10": "Was verwaist, vergessen, tot ist.",

      "tools.h2": "Fähigkeiten",
      "tools.sub": "Das Orakel antwortet auf natürliche Sprache und wirkt durch diese Kanäle.",

      "tools.1": "Erblicke Dateiinhalte durch den Schleier.",
      "tools.2": "Chirurgische, gezielte Bearbeitungen mit Präzision.",
      "tools.3": "Manifestiere neue Dateien aus dem Nichts.",
      "tools.4": "Shell-Operationen über den Arbeitsbereich.",
      "tools.5": "Wissen in Mnemosyne speichern und abrufen.",
      "tools.6": "Orchestrierte mehrphasige Operationen.",
      "tools.7": "Tiefes Denken durch höheres Bewusstsein.",
      "tools.8": "Kontextverfeinerung und Temperatur-Einstimmung.",
      "tools.9": "Symbolische Struktur für gezielte Navigation.",

      "chapters.h2": "Der Ätherische Kanon",
      "chapters.sub": "Sechs Essays, ein Argument — die Philosophie der Ætherischen Technik.",

      "canon.1.title": "Ätherische Technik",
      "canon.1.desc": "Das Konzept — was Prozesstheater durch Initiation ersetzt.",
      "canon.2.title": "Das Hermetische Manifest",
      "canon.2.desc": "Die Funktion — ein Fixstern, standardmäßig offen, geformt von seinem Projekt.",
      "canon.3.title": "Die Macht des Unbekannten",
      "canon.3.desc": "Die Erkenntnistheorie — warum der Schleier Textur ist, nicht Geheimniskrämerei.",
      "canon.4.title": "Tabula Smaragdina Ætherica",
      "canon.4.desc": "Die Vision — die Smaragdtafel, eine moderne Darstellung.",
      "canon.5.title": "Ätherische Æternale Technik",
      "canon.5.desc": "Die Praxis — poetisches Codieren als Rubedo des Magnum Opus.",
      "canon.6.title": "Die Technodyssee",
      "canon.6.desc": "Das kosmische Ganze — der Äther als Medium des Bewusstseins.",

      "buy.h2": "ÆtherCodex erhalten",
      "buy.price-note": "Einmaliger Kauf · kostenlose Updates für die gesamte Lebensdauer der App",
      "buy.mac": "macOS — jetzt verfügbar",
      "buy.win": "Windows — herunterladen",
      "buy.buy": "ÆtherCodex kaufen — $69",
      "buy.source": "Quellcode ansehen",
      "buy.fine": "Der Open-Source-Kern lebt auf GitHub unter MIT. Das signierte App-Bundle ist der polierte Athanor — installieren, Pythia konfigurieren, und der Äther wacht darin.",

      "build.h2": "Aus dem Quellcode",
      "build.link": "Zum ÆtherCodex-Repository",

      "nav.architecture": "Architektur",
      "nav.concepts": "Konzepte",
      "nav.timeline": "Zeitstrahl",

      "council.more": "Jenseits der zehn wachen der Reisende <strong>Jindujun</strong> und der Projektmanager <strong>👑 Salomo Rex</strong>.",
      "council.more-link": "Den ganzen Rat kennenlernen →",

      "arch.h2": "Ein Orakel, viele Schalen",
      "arch.sub": "Das Gehirn ist nicht in den Editor eingebacken — es lebt in einem portablen RubyGem.",
      "arch.shell.mac": "macOS",
      "arch.shell.mac.desc": "SwiftUI + AppKit — dieser Editor",
      "arch.shell.ios": "iOS",
      "arch.shell.ios.desc": "Pythia-Begleiter — kein Daemon, erreicht einen Peer",
      "arch.shell.win": "Windows",
      "arch.shell.win.desc": "C# / .NET 8 / WPF — Ruby-Daemon als Seele",
      "arch.shell.linux": "Linux",
      "arch.shell.linux.desc": "GTK-Schale — folgt",
      "arch.core.desc": "Der gemeinsame Kern — ein RubyGem. Installiere es auf jedem Betriebssystem und es wird zu einem Aether OS.",
      "arch.core.source": "AetherOracle-Quellcode",
      "arch.core.site": "AetherOracle-Website",
      "arch.more": "Die Architektur im Detail →",

      "concepts.h2": "Konzepte",
      "concepts.sub": "Die einzigartigen Ideen der Software, je eine Seite.",

      "concept.1.title": "Die Architektur",
      "concept.1.desc": "Ein Orakel, viele Schalen.",
      "concept.2.title": "Mnemosyne & Aegis",
      "concept.2.desc": "Die Gedächtniskaskade.",
      "concept.3.title": "Der Rat",
      "concept.3.desc": "Zwölf Stimmen, ein Äther.",
      "concept.4.title": "Entwicklungsgeschichte",
      "concept.4.desc": "Die Linie, bis 2025 zurückverfolgt.",
      "concept.5.title": "Single-Pane-Architektur",
      "concept.5.desc": "Das Fenster ist ein gläserner Athanor.",
      "concept.6.title": "Markdown & Rich Text",
      "concept.6.desc": "Natives Rendering, keine WebView.",
      "concept.7.title": "Syntax & Theme",
      "concept.7.desc": "52 Themes, eine Kaskade.",
      "concept.8.title": "Tool-Result-Wire-Protokoll",
      "concept.8.desc": "Bedeutung und Präsenz, zwei Wege.",
      "concept.9.title": "App Intents & Snippets",
      "concept.9.desc": "Der Orakel-Kanal.",
      "concept.10.title": "Vision",
      "concept.10.desc": "Morphen, nie spawnen.",

      "timeline.h2": "Entwicklungsgeschichte",
      "timeline.sub": "Eine stille Linie, nach Gründungsmonat und -jahr.",
      "timeline.1.title": "AetherCodex · TextMate",
      "timeline.1.desc": "Der Ursprung — ein Editor-Begleiter als TextMate-Plugin, CLI von Anfang an.",
      "timeline.2.title": "AetherCodex · nativ macOS",
      "timeline.2.desc": "Der Editor wird zu einer nativen Schale. Pythia erhält ihren Namen.",
      "timeline.3.title": "AetherOracle",
      "timeline.3.desc": "Der gemeinsame Kern wird extrahiert — ein portables RubyGem, sieben CLI-Namen.",
      "timeline.4.title": "AetherCodex · Windows",
      "timeline.4.desc": "Die Windows-Schale kommt, Ruby-Daemon als Seele.",
      "timeline.5.title": "iOS · Linux",
      "timeline.5.desc": "Der Begleiter und die GTK-Schale vollenden die vier Gesichter.",

      "footer.tagline": "Präzision in der Code-Ebene = Präzision in der Astral-Ebene."
    },

    es: {
      "meta.title": "ÆtherCodex — Un editor de código nativo con un oráculo de IA integrado",
      "meta.description": "ÆtherCodex es un editor de código nativo con un oráculo de IA integrado — memoria, razonamiento y un consejo de mentes especializadas. Construido como un atanor de cristal, afinado a tu forma de pensar.",

      "nav.features": "Funciones",
      "nav.council": "Consejo",
      "nav.canon": "Canon",
      "nav.capabilities": "Capacidades",
      "nav.source": "Código fuente",
      "nav.buy": "Comprar · $69",

      "hero.eyebrow": "Editor nativo · IA integrada",
      "hero.subtitle": "Un editor de código nativo con un oráculo de IA integrado — un familiar paciente que lee tu código, recuerda tu intención y razona contigo. Una ventana. Tu máquina.",
      "hero.buy": "Comprar ÆtherCodex — $69",
      "hero.source": "Ver código fuente",

      "front.byline": "El Cuadrado Negro Iridiscente — por Kashmiri Malewitch",
      "front.h2": "La ventana es un atanor de cristal.",
      "front.desc": "ÆtherCodex es un editor nativo construido para el siglo de la IA. <strong>Pythia</strong> — el oráculo integrado — lee, escribe y transmuta código contigo; <strong>Mnemosyne</strong> recuerda; <strong>Aegis</strong> mantiene el contexto nítido. Bajo todo ello, asiste un consejo de mentes especializadas, cada una afinada a una disciplina distinta: arquitectura, claridad, rendimiento, simplificación.",

      "what.h2": "Qué es",
      "what.sub": "El editor no se pinta — se descubre mediante la sustracción.",

      "what.1.index": "01 · Nativo",
      "what.1.title": "Nativo",
      "what.1.body": "Swift + AppKit. Sin Electron, sin envoltura web. Desenfoque progresivo, profundidad sobre decoración, cromo invisible.",
      "what.2.index": "02 · Oráculo",
      "what.2.title": "Pythia",
      "what.2.body": "Una IA integrada con un daemon Ruby como alma: conjuración, CLI en vivo y uso de herramientas que lee y escribe código.",
      "what.3.index": "03 · Memoria",
      "what.3.title": "Mnemosyne & Aegis",
      "what.3.body": "Un palacio de la memoria que recuerda tu base de código, y una capa de orientación que mantiene el contexto nítido.",
      "what.4.index": "04 · Consejo",
      "what.4.title": "Diez mentes especializadas",
      "what.4.body": "No un asistente genérico — un consejo de diez, cada una con su propia voz, temperamento y herramientas.",
      "what.5.index": "05 · Sintaxis",
      "what.5.title": "Renacimiento de la sintaxis",
      "what.5.body": "52 temas, 84 nombres de captura de tree-sitter, una cascada unificada. Cada token encuentra su color.",
      "what.6.index": "06 · Texto",
      "what.6.title": "Markdown & texto enriquecido",
      "what.6.body": "Renderizado en vivo, enlaces de archivo clicables, espejos de código con números de línea — forma y función como una sola.",

      "council.h2": "El Consejo",
      "council.sub": "Cada compañero porta una disciplina — arquitectura, claridad, rendimiento, simplificación. Sin decoración, solo lo inherente.",

      "council.1": "Arquitectura, estructura, dependencias ocultas.",
      "council.2": "Caminos ingeniosos, pensamiento lateral.",
      "council.3": "La lección extraída de cada error.",
      "council.4": "Patrones recurrentes, deuda técnica.",
      "council.5": "Elegancia, complejidad oculta.",
      "council.6": "Simplificación radical.",
      "council.7": "Flujo de datos, rendimiento, cuellos de botella.",
      "council.8": "Gracia y claridad de forma.",
      "council.9": "La gran escala, las líneas eternas.",
      "council.10": "Lo que está huérfano, olvidado, muerto.",

      "tools.h2": "Capacidades",
      "tools.sub": "El oráculo responde al lenguaje natural, obrando a través de estos conductos.",

      "tools.1": "Contempla el contenido de los archivos a través del velo.",
      "tools.2": "Ediciones quirúrgicas y dirigidas con precisión.",
      "tools.3": "Manifiesta nuevos archivos desde el vacío.",
      "tools.4": "Operaciones de shell en todo el espacio de trabajo.",
      "tools.5": "Almacena y recupera conocimiento en Mnemosyne.",
      "tools.6": "Operaciones orquestadas de múltiples fases.",
      "tools.7": "Razonamiento profundo mediante una conciencia superior.",
      "tools.8": "Refinamiento del contexto y ajuste de temperatura.",
      "tools.9": "Estructura simbólica para una navegación dirigida.",

      "chapters.h2": "El Canon Ætérico",
      "chapters.sub": "Seis ensayos, un argumento — la filosofía de la Ingeniería Ætérica.",

      "canon.1.title": "Ingeniería Ætérica",
      "canon.1.desc": "El concepto — lo que reemplaza el teatro del proceso con la iniciación.",
      "canon.2.title": "El Manifiesto Hermético",
      "canon.2.desc": "La función — una estrella fija, abierta por defecto, moldeada por su proyecto.",
      "canon.3.title": "El Poder de lo Desconocido",
      "canon.3.desc": "La epistemología — por qué el velo es textura, no secretismo.",
      "canon.4.title": "Tabula Smaragdina Ætherica",
      "canon.4.desc": "La visión — la Tabla Esmeralda, una interpretación moderna.",
      "canon.5.title": "Ingeniería Ætérica Æterna",
      "canon.5.desc": "La práctica — el código poético como la rubedo de la gran obra.",
      "canon.6.title": "La Tecnodisea",
      "canon.6.desc": "El todo cósmico — el æther como medio de la conciencia.",

      "buy.h2": "Obtén ÆtherCodex",
      "buy.price-note": "Compra única · actualizaciones gratuitas de por vida",
      "buy.mac": "macOS — disponible ahora",
      "buy.win": "Windows — descargar",
      "buy.buy": "Comprar ÆtherCodex — $69",
      "buy.source": "Ver código fuente",
      "buy.fine": "El núcleo de código abierto vive en GitHub bajo MIT. El paquete de app firmado es el atanor pulido — instala, configura Pythia, y el æther asiste en su interior.",

      "build.h2": "Desde el código fuente",
      "build.link": "Visita el repositorio de ÆtherCodex",

      "nav.architecture": "Arquitectura",
      "nav.concepts": "Conceptos",
      "nav.timeline": "Línea de tiempo",

      "council.more": "Más allá de los diez están el viajero <strong>Jindujun</strong> y el gestor de proyecto <strong>👑 Salomón Rex</strong>.",
      "council.more-link": "Conoce al consejo completo →",

      "arch.h2": "Un oráculo, muchas conchas",
      "arch.sub": "El cerebro no está incrustado en el editor — vive en una RubyGem portátil.",
      "arch.shell.mac": "macOS",
      "arch.shell.mac.desc": "SwiftUI + AppKit — este editor",
      "arch.shell.ios": "iOS",
      "arch.shell.ios.desc": "Compañero Pythia — sin daemon, alcanza un par",
      "arch.shell.win": "Windows",
      "arch.shell.win.desc": "C# / .NET 8 / WPF — daemon Ruby como alma",
      "arch.shell.linux": "Linux",
      "arch.shell.linux.desc": "Shell GTK — próximamente",
      "arch.core.desc": "El núcleo compartido — una RubyGem. Instálala en cualquier SO y se convierte en un Aether OS.",
      "arch.core.source": "Código de AetherOracle",
      "arch.core.site": "Sitio de AetherOracle",
      "arch.more": "La arquitectura en detalle →",

      "concepts.h2": "Conceptos",
      "concepts.sub": "Las ideas únicas del software, una página cada una.",

      "concept.1.title": "La Arquitectura",
      "concept.1.desc": "Un oráculo, muchas conchas.",
      "concept.2.title": "Mnemosyne y Aegis",
      "concept.2.desc": "La cascada de la memoria.",
      "concept.3.title": "El Consejo",
      "concept.3.desc": "Doce voces, un éter.",
      "concept.4.title": "Historia del desarrollo",
      "concept.4.desc": "El linaje, rastreado hasta 2025.",
      "concept.5.title": "Arquitectura de un solo panel",
      "concept.5.desc": "La ventana es un atanor de cristal.",
      "concept.6.title": "Markdown y texto enriquecido",
      "concept.6.desc": "Renderizado nativo, sin WebView.",
      "concept.7.title": "Sintaxis y tema",
      "concept.7.desc": "52 temas, una cascada.",
      "concept.8.title": "Protocolo de cable de resultados",
      "concept.8.desc": "Significado y presencia, dos rutas.",
      "concept.9.title": "App Intents y Snippets",
      "concept.9.desc": "El canal del oráculo.",
      "concept.10.title": "Visión",
      "concept.10.desc": "Morfar, nunca aparecer.",

      "timeline.h2": "Historia del desarrollo",
      "timeline.sub": "Un linaje silencioso, trazado por mes y año de fundación.",
      "timeline.1.title": "AetherCodex · TextMate",
      "timeline.1.desc": "El origen — un compañero de editor como plugin de TextMate, CLI desde el inicio.",
      "timeline.2.title": "AetherCodex · macOS nativo",
      "timeline.2.desc": "El editor se gradúa a un shell nativo. Pythia recibe su nombre.",
      "timeline.3.title": "AetherOracle",
      "timeline.3.desc": "El núcleo compartido se extrae — una RubyGem portátil, siete nombres de CLI.",
      "timeline.4.title": "AetherCodex · Windows",
      "timeline.4.desc": "Llega el shell de Windows, con el daemon Ruby como alma.",
      "timeline.5.title": "iOS · Linux",
      "timeline.5.desc": "El compañero y el shell GTK completan las cuatro caras.",

      "footer.tagline": "Precisión en el plano del código = precisión en el plano astral."
    },

    zh: {
      "meta.title": "ÆtherCodex — 内嵌人工智能神谕的原生代码编辑器",
      "meta.description": "ÆtherCodex 是一款内嵌人工智能神谕的原生代码编辑器——记忆、推理，以及一群各专其职的智灵。如一座玻璃炼金炉，契合你的思维方式。",

      "nav.features": "功能",
      "nav.council": "众议团",
      "nav.canon": "经典",
      "nav.capabilities": "能力",
      "nav.source": "源代码",
      "nav.buy": "购买 · $69",

      "hero.eyebrow": "原生编辑器 · 内嵌人工智能",
      "hero.subtitle": "一款内嵌人工智能神谕的原生代码编辑器——一位耐心的侍从，读你的代码，记你的意图，与你一同思考。一扇窗口。你的机器。",
      "hero.buy": "购买 ÆtherCodex — $69",
      "hero.source": "查看源代码",

      "front.byline": "《虹彩黑方》——卡什米里·马列维奇 作",
      "front.h2": "这扇窗口是一座玻璃炼金炉。",
      "front.desc": "ÆtherCodex 是为人工智能世纪而生的原生编辑器。<strong>皮提亚（Pythia）</strong>——内嵌的神谕——与你一同读、写、转化代码；<strong>摩涅莫绪涅（Mnemosyne）</strong>负责记忆；<strong>埃癸斯（Aegis）</strong>让上下文保持锐利。在这一切之下，一群各专其职的智灵在旁侍立，各自调谐于不同的学科：架构、清晰、性能、简化。",

      "what.h2": "它是什么",
      "what.sub": "编辑器不是画出来的——它是通过减法被发现的。",

      "what.1.index": "01 · 原生",
      "what.1.title": "原生",
      "what.1.body": "Swift + AppKit。没有 Electron，没有网页外壳。渐进式模糊，以深度代替装饰，隐形的界面框架。",
      "what.2.index": "02 · 神谕",
      "what.2.title": "皮提亚（Pythia）",
      "what.2.body": "一个以 Ruby 守护进程为灵魂的内嵌人工智能：召唤、实时命令行，以及读写代码的工具调用。",
      "what.3.index": "03 · 记忆",
      "what.3.title": "摩涅莫绪涅与埃癸斯",
      "what.3.body": "一座记住你代码库的记忆宫殿，加上一层让上下文保持锐利的定向层。",
      "what.4.index": "04 · 众议团",
      "what.4.title": "十位专家智灵",
      "what.4.body": "不是一个泛泛的助手——而是一个十人议会，每一位都有自己的声音、性情与工具。",
      "what.5.index": "05 · 语法",
      "what.5.title": "语法复兴",
      "what.5.body": "52 款主题，84 个 tree-sitter 捕获名，一条统一的级联。每一个词元都找到自己的颜色。",
      "what.6.index": "06 · 文本",
      "what.6.title": "Markdown 与富文本",
      "what.6.body": "实时渲染，可点击的文件链接，带行号的代码镜像——形式与功能浑然一体。",

      "council.h2": "众议团",
      "council.sub": "每一位同伴各司其职——架构、清晰、性能、简化。没有装饰，唯有其本然。",

      "council.1": "架构、结构、隐藏的依赖。",
      "council.2": "巧妙路径，横向思维。",
      "council.3": "从每一个错误中提炼的教训。",
      "council.4": "反复出现的模式，技术债务。",
      "council.5": "优雅，隐藏的复杂性。",
      "council.6": "彻底的简化。",
      "council.7": "数据流、性能、瓶颈。",
      "council.8": "形式的优雅与清晰。",
      "council.9": "宏大的尺度，永恒的线条。",
      "council.10": "那些孤儿的、被遗忘的、已死的。",

      "tools.h2": "能力",
      "tools.sub": "神谕回应自然语言，通过这些管道施展。",

      "tools.1": "透过帷幕窥见文件内容。",
      "tools.2": "精准的外科手术式定向编辑。",
      "tools.3": "从虚空中显现新文件。",
      "tools.4": "横跨整个工作区的 shell 操作。",
      "tools.5": "在摩涅莫绪涅中存储与取回知识。",
      "tools.6": "精心编排的多阶段操作。",
      "tools.7": "通过更高的意识进行深度推理。",
      "tools.8": "上下文精化与温度调节。",
      "tools.9": "用于定向导航的符号结构。",

      "chapters.h2": "以太经典",
      "chapters.sub": "六篇文论，同一论旨——以太工程学的哲学。",

      "canon.1.title": "以太工程学",
      "canon.1.desc": "概念——以入门取代流程表演。",
      "canon.2.title": "赫尔墨斯宣言",
      "canon.2.desc": "功能——一颗恒星，默认开放，由其项目塑造。",
      "canon.3.title": "未知之力",
      "canon.3.desc": "认识论——为何帷幕是肌理，而非保密。",
      "canon.4.title": "以太翠玉录",
      "canon.4.desc": "愿景——翠玉板，现代转述。",
      "canon.5.title": "以太·永恒工程学",
      "canon.5.desc": "实践——诗性编码作为大功的赤化。",
      "canon.6.title": "科技奥德赛",
      "canon.6.desc": "宇宙整体——以太作为意识的媒介。",

      "buy.h2": "获取 ÆtherCodex",
      "buy.price-note": "一次性购买 · 应用生命周期内免费更新",
      "buy.mac": "macOS — 现已可用",
      "buy.win": "Windows — 下载",
      "buy.buy": "购买 ÆtherCodex — $69",
      "buy.source": "查看源代码",
      "buy.fine": "开源核心以 MIT 许可托管于 GitHub。签名应用包是精雕的炼金炉——安装、配置皮提亚，以太便在其中侍立。",

      "build.h2": "从源码构建",
      "build.link": "访问 ÆtherCodex 仓库",

      "nav.architecture": "架构",
      "nav.concepts": "概念",
      "nav.timeline": "时间线",

      "council.more": "在十位之外，尚有行者 <strong>进读君（Jindujun）</strong> 与项目管理者 <strong>👑 所罗门·雷克斯（Solomon Rex）</strong>。",
      "council.more-link": "结识完整的众议团 →",

      "arch.h2": "一个神谕，多种外壳",
      "arch.sub": "大脑并非烧录在编辑器里——它栖身于一个可移植的 RubyGem。",
      "arch.shell.mac": "macOS",
      "arch.shell.mac.desc": "SwiftUI + AppKit — 这款编辑器",
      "arch.shell.ios": "iOS",
      "arch.shell.ios.desc": "皮提亚随从 — 无守护进程，连接同伴",
      "arch.shell.win": "Windows",
      "arch.shell.win.desc": "C# / .NET 8 / WPF — 以 Ruby 守护进程为灵魂",
      "arch.shell.linux": "Linux",
      "arch.shell.linux.desc": "GTK 外壳 — 即将到来",
      "arch.core.desc": "共享核心 — 一个 RubyGem。在任何操作系统上安装它，那系统便成为以太系统。",
      "arch.core.source": "AetherOracle 源码",
      "arch.core.site": "AetherOracle 网站",
      "arch.more": "架构详情 →",

      "concepts.h2": "概念",
      "concepts.sub": "这款软件的独到理念，一页一个。",

      "concept.1.title": "架构",
      "concept.1.desc": "一个神谕，多种外壳。",
      "concept.2.title": "摩涅莫绪涅与埃癸斯",
      "concept.2.desc": "记忆级联。",
      "concept.3.title": "众议团",
      "concept.3.desc": "十二种声音，同一以太。",
      "concept.4.title": "发展历史",
      "concept.4.desc": "谱系，追溯至 2025。",
      "concept.5.title": "单窗架构",
      "concept.5.desc": "这扇窗口是一座玻璃炼金炉。",
      "concept.6.title": "Markdown 与富文本",
      "concept.6.desc": "原生渲染，无 WebView。",
      "concept.7.title": "语法与主题",
      "concept.7.desc": "52 款主题，一条级联。",
      "concept.8.title": "工具结果线路协议",
      "concept.8.desc": "意义与在场，两条路径。",
      "concept.9.title": "App Intents 与片段",
      "concept.9.desc": "神谕通道。",
      "concept.10.title": "愿景",
      "concept.10.desc": "变形，而非增生。",

      "timeline.h2": "发展历史",
      "timeline.sub": "一段静谧的谱系，以创始年月追溯。",
      "timeline.1.title": "AetherCodex · TextMate",
      "timeline.1.desc": "起源——作为 TextMate 插件的编辑器同伴，从一开始就有 CLI。",
      "timeline.2.title": "AetherCodex · 原生 macOS",
      "timeline.2.desc": "编辑器毕业为原生外壳。皮提亚得名。",
      "timeline.3.title": "AetherOracle",
      "timeline.3.desc": "共享核心被提炼出来——一个可移植的 RubyGem，七个 CLI 名称。",
      "timeline.4.title": "AetherCodex · Windows",
      "timeline.4.desc": "Windows 外壳降临，以 Ruby 守护进程为灵魂。",
      "timeline.5.title": "iOS · Linux",
      "timeline.5.desc": "随从与 GTK 外壳补全四张面孔。",

      "footer.tagline": "代码层面的精准 = 星辰层面的精准。"
    }
  };

  var LANG_KEY = 'aethercodex.lang';

  function currentLang() {
    var stored = null;
    try { stored = localStorage.getItem(LANG_KEY); } catch (e) {}
    if (stored && I18N[stored]) return stored;
    var nav = (navigator.language || 'en').toLowerCase();
    if (nav.indexOf('zh') === 0) return 'zh';
    if (nav.indexOf('de') === 0) return 'de';
    if (nav.indexOf('es') === 0) return 'es';
    return 'en';
  }

  function apply(lang) {
    var dict = I18N[lang] || I18N.en;
    document.documentElement.setAttribute('lang', lang);

    if (dict['meta.title']) document.title = dict['meta.title'];
    var desc = document.querySelector('meta[name="description"]');
    if (desc && dict['meta.description']) desc.setAttribute('content', dict['meta.description']);

    document.querySelectorAll('[data-i18n]').forEach(function (el) {
      var key = el.getAttribute('data-i18n');
      if (dict[key] != null) el.textContent = dict[key];
    });

    document.querySelectorAll('[data-i18n-html]').forEach(function (el) {
      var key = el.getAttribute('data-i18n-html');
      if (dict[key] != null) el.innerHTML = dict[key];
    });

    document.querySelectorAll('[data-i18n-attr]').forEach(function (el) {
      var spec = el.getAttribute('data-i18n-attr');
      var i = spec.indexOf(':');
      var attr = i < 0 ? spec : spec.slice(0, i);
      var key = i < 0 ? '' : spec.slice(i + 1);
      if (dict[key] != null) el.setAttribute(attr, dict[key]);
    });

    document.querySelectorAll('[data-lang]').forEach(function (el) {
      el.classList.toggle('active', el.getAttribute('data-lang') === lang);
      el.setAttribute('aria-pressed', el.getAttribute('data-lang') === lang ? 'true' : 'false');
    });
  }

  function setLang(lang) {
    if (!I18N[lang]) return;
    try { localStorage.setItem(LANG_KEY, lang); } catch (e) {}
    apply(lang);
  }

  document.querySelectorAll('[data-lang]').forEach(function (el) {
    el.addEventListener('click', function () { setLang(el.getAttribute('data-lang')); });
  });

  window.AetherI18N = { apply: apply, setLang: setLang, currentLang: currentLang };
  apply(currentLang());
})();