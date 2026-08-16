local GetText = {}

local template_fn
do
  local ok, util = pcall(require, "ffi/util")
  if ok and util and type(util.template) == "function" then
    template_fn = util.template
  else
    template_fn = function(text, ...)
      local args = { n = select("#", ...), ... }
      return (tostring(text):gsub("%%(%d+)", function(index)
        return tostring(args[tonumber(index)] or "")
      end))
    end
  end
end
GetText.template = template_fn

local koreader_gettext
do
  local ok, gettext = pcall(require, "gettext")
  if ok and gettext then
    koreader_gettext = gettext
  else
    koreader_gettext = setmetatable({ current_lang = "C" }, {
      __call = function(_, msgid)
        return msgid
      end,
    })
  end
end

-- English source strings are the msgids. Only non-English catalogs live here.
local translations = {
  es = {
    ["AI Dictionary"] = "Diccionario IA",
    ["AI Explain"] = "Explicar con IA",
    ["AI Simplify"] = "Simplificar con IA",
    ["AI dictionary and explainer"] = "Diccionario y explicador con IA",
    ["AI Dictionary settings"] = "Ajustes de Diccionario IA",
    ["AI Dictionary Lookups Report"] = "Informe de consultas de Diccionario IA",
    ["API key"] = "Clave API",
    ["Text endpoint URL"] = "URL del endpoint de texto",
    ["Text model"] = "Modelo de texto",
    ["Provider"] = "Proveedor",
    ["Google Gemini"] = "Google Gemini",
    ["OpenAI"] = "OpenAI",
    ["OpenRouter"] = "OpenRouter",
    ["DeepSeek"] = "DeepSeek",
    ["Custom / Other"] = "Personalizado / Otro",
    ["Custom model…"] = "Modelo personalizado…",
    ["free"] = "gratis",
    ["paid"] = "de pago",
    ["Output language"] = "Idioma de salida",
    ["Automatic (follow system)"] = "Automático (seguir el sistema)",
    ["Automatic (follow book)"] = "Automático (seguir el libro)",
    ["Additional parameters"] = "Parámetros adicionales",
    ["Voice endpoint URL"] = "URL del endpoint de voz",
    ["Voice model"] = "Modelo de voz",
    ["Voice"] = "Voz",
    ["Voice speed"] = "Velocidad de voz",
    ["Show images"] = "Mostrar imágenes",
    ["Debug mode"] = "Modo depuración",
    ["Check for updates"] = "Buscar actualizaciones",
    ["Check for updates now"] = "Buscar actualizaciones ahora",
    ["Delete custom setting"] = "Eliminar ajuste personalizado",
    ["Add setting"] = "Añadir ajuste",
    ["Not set"] = "Sin definir",
    ["set"] = "definida",
    ["Cancel"] = "Cancelar",
    ["Save"] = "Guardar",
    ["Next"] = "Siguiente",
    ["Ask"] = "Preguntar",
    ["Update"] = "Actualizar",
    ["Quit"] = "Salir",
    ["Generate Report"] = "Generar informe",
    ["Timeframe"] = "Periodo",
    ["Timeframe: %1"] = "Periodo: %1",
    ["Today"] = "Hoy",
    ["3 Days"] = "3 días",
    ["7 Days"] = "7 días",
    ["1 Month"] = "1 mes",
    ["3 Months"] = "3 meses",
    ["1 Year"] = "1 año",
    ["All Time"] = "Todo el tiempo",
    ["Getting the answer..."] = "Obteniendo la respuesta...",
    ["Generating report..."] = "Generando informe...",
    ["Loading..."] = "Cargando...",
    ["Ask another question"] = "Hacer otra pregunta",
    ["Enter your question for ChatGPT."] = "Escribe tu pregunta para la IA.",
    ["Word copied to clipboard."] = "Palabra copiada al portapapeles.",
    ["Selection copied to clipboard."] = "Selección copiada al portapapeles.",
    ["Highlighted text: "] = "Texto resaltado: ",
    ["User: "] = "Usuario: ",
    ["ChatGPT: "] = "IA: ",
    ["Edit %1"] = "Editar %1",
    ["Set %1"] = "Definir %1",
    ["Enter a Lua literal: string, number, boolean, or table."] = "Introduce un literal Lua: cadena, número, booleano o tabla.",
    ["Enter a Lua identifier, for example: additional_parameters"] = "Introduce un identificador Lua, por ejemplo: additional_parameters",
    ["AI Dictionary settings saved."] = "Ajustes de Diccionario IA guardados.",
    ["Could not save configuration.lua:\n%1"] = "No se pudo guardar configuration.lua:\n%1",
    ["Please enter a valid number."] = "Introduce un número válido.",
    ["Please enter a valid non-nil Lua value.\n%1"] = "Introduce un valor Lua válido distinto de nil.\n%1",
    ["Setting names must be Lua identifiers."] = "Los nombres de ajuste deben ser identificadores Lua.",
    ["That setting is no longer used."] = "Ese ajuste ya no se usa.",
    ["That setting is already available in settings."] = "Ese ajuste ya está disponible en la configuración.",
    ["That setting already exists."] = "Ese ajuste ya existe.",
    ["No lookups found for %1."] = "No hay consultas para %1.",
    ["Error querying AI: %1"] = "Error al consultar la IA: %1",
    ["No API key configured."] = "No hay clave API configurada.",
    ["Incomplete AI response: the connection ended before the stream completed."] = "Respuesta de la IA incompleta: la conexión terminó antes de que acabara el flujo.",
    ["Debug: prompt sent to AI"] = "Depuración: prompt enviado a la IA",
    ["AI Dictionary is up to date."] = "Diccionario IA está actualizado.",
    ["An AI Dictionary update check is already in progress."] = "Ya hay una comprobación de actualizaciones de Diccionario IA en curso.",
    ["Could not check for updates while offline."] = "No se pueden buscar actualizaciones sin conexión.",
    ["Could not check for AI Dictionary updates:\n%1"] = "No se pudieron buscar actualizaciones de Diccionario IA:\n%1",
    ["AI Dictionary %1 is available.\n\nInstalled version: %2\n\nUpdate now?"] = "Diccionario IA %1 está disponible.\n\nVersión instalada: %2\n\n¿Actualizar ahora?",
    ["Updating AI Dictionary..."] = "Actualizando Diccionario IA...",
    ["AI Dictionary update failed:\n%1"] = "Error al actualizar Diccionario IA:\n%1",
    ["AI Dictionary was updated.\n\nPlease quit and restart KOReader to load the new version."] = "Diccionario IA se ha actualizado.\n\nCierra y reinicia KOReader para cargar la nueva versión.",
    ["Could not open settings:\n%1"] = "No se pudieron abrir los ajustes:\n%1",
    ["Request timeout"] = "Tiempo de espera",
    ["Request timeout: %1 s"] = "Tiempo de espera: %1 s",
    ["How long to wait for an AI reply before asking whether to keep waiting (%1–%2 seconds)."] = "Cuánto esperar una respuesta de la IA antes de preguntar si seguir esperando (%1–%2 segundos).",
    ["Please enter a whole number of seconds between %1 and %2."] = "Introduce un número entero de segundos entre %1 y %2.",
    ["Maximum predefined request timeout reached (%1 seconds).\nAutomatic cancellation in %2..."] = "Se alcanzó el tiempo de espera máximo predefinido (%1 segundos).\nCancelación automática en %2...",
    ["Wait another %1 seconds"] = "Esperar otros %1 segundos",
    ["Request cancelled after the maximum timeout (%1 seconds)."] = "Consulta cancelada tras el tiempo de espera máximo (%1 segundos).",
  },
  fr = {
    ["AI Dictionary"] = "Dictionnaire AI",
    ["AI Explain"] = "Expliquer avec l'IA",
    ["AI Simplify"] = "Simplifier avec l'IA",
    ["AI dictionary and explainer"] = "Dictionnaire et explicateur IA",
    ["AI Dictionary settings"] = "Paramètres Dictionnaire AI",
    ["AI Dictionary Lookups Report"] = "Rapport des consultations Dictionnaire AI",
    ["API key"] = "Clé API",
    ["Text endpoint URL"] = "URL de l'endpoint texte",
    ["Text model"] = "Modèle de texte",
    ["Provider"] = "Fournisseur",
    ["Google Gemini"] = "Google Gemini",
    ["OpenAI"] = "OpenAI",
    ["OpenRouter"] = "OpenRouter",
    ["DeepSeek"] = "DeepSeek",
    ["Custom / Other"] = "Personnalisé / Autre",
    ["Custom model…"] = "Modèle personnalisé…",
    ["free"] = "gratuit",
    ["paid"] = "payant",
    ["Output language"] = "Langue des réponses",
    ["Automatic (follow system)"] = "Automatique (suivre le système)",
    ["Automatic (follow book)"] = "Automatique (suivre le livre)",
    ["Additional parameters"] = "Paramètres supplémentaires",
    ["Voice endpoint URL"] = "URL de l'endpoint vocal",
    ["Voice model"] = "Modèle vocal",
    ["Voice"] = "Voix",
    ["Voice speed"] = "Vitesse de la voix",
    ["Show images"] = "Afficher les images",
    ["Debug mode"] = "Mode débogage",
    ["Check for updates"] = "Rechercher les mises à jour",
    ["Check for updates now"] = "Rechercher les mises à jour maintenant",
    ["Delete custom setting"] = "Supprimer un réglage personnalisé",
    ["Add setting"] = "Ajouter un réglage",
    ["Not set"] = "Non défini",
    ["set"] = "définie",
    ["Cancel"] = "Annuler",
    ["Save"] = "Enregistrer",
    ["Next"] = "Suivant",
    ["Ask"] = "Demander",
    ["Update"] = "Mettre à jour",
    ["Quit"] = "Quitter",
    ["Generate Report"] = "Générer le rapport",
    ["Timeframe"] = "Période",
    ["Timeframe: %1"] = "Période : %1",
    ["Today"] = "Aujourd'hui",
    ["3 Days"] = "3 jours",
    ["7 Days"] = "7 jours",
    ["1 Month"] = "1 mois",
    ["3 Months"] = "3 mois",
    ["1 Year"] = "1 an",
    ["All Time"] = "Tout",
    ["Getting the answer..."] = "Récupération de la réponse...",
    ["Generating report..."] = "Génération du rapport...",
    ["Loading..."] = "Chargement...",
    ["Ask another question"] = "Poser une autre question",
    ["Enter your question for ChatGPT."] = "Saisissez votre question pour l'IA.",
    ["Word copied to clipboard."] = "Mot copié dans le presse-papiers.",
    ["Selection copied to clipboard."] = "Sélection copiée dans le presse-papiers.",
    ["Highlighted text: "] = "Texte surligné : ",
    ["User: "] = "Utilisateur : ",
    ["ChatGPT: "] = "IA : ",
    ["Edit %1"] = "Modifier %1",
    ["Set %1"] = "Définir %1",
    ["Enter a Lua literal: string, number, boolean, or table."] = "Saisissez un littéral Lua : chaîne, nombre, booléen ou table.",
    ["Enter a Lua identifier, for example: additional_parameters"] = "Saisissez un identifiant Lua, par exemple : additional_parameters",
    ["AI Dictionary settings saved."] = "Paramètres Dictionnaire AI enregistrés.",
    ["Could not save configuration.lua:\n%1"] = "Impossible d'enregistrer configuration.lua :\n%1",
    ["Please enter a valid number."] = "Veuillez saisir un nombre valide.",
    ["Please enter a valid non-nil Lua value.\n%1"] = "Veuillez saisir une valeur Lua valide (non nil).\n%1",
    ["Setting names must be Lua identifiers."] = "Les noms de réglage doivent être des identifiants Lua.",
    ["That setting is no longer used."] = "Ce réglage n'est plus utilisé.",
    ["That setting is already available in settings."] = "Ce réglage est déjà disponible dans les paramètres.",
    ["That setting already exists."] = "Ce réglage existe déjà.",
    ["No lookups found for %1."] = "Aucune consultation pour %1.",
    ["Error querying AI: %1"] = "Erreur lors de la requête IA : %1",
    ["No API key configured."] = "Aucune clé API configurée.",
    ["Incomplete AI response: the connection ended before the stream completed."] = "Réponse IA incomplète : la connexion s'est terminée avant la fin du flux.",
    ["Debug: prompt sent to AI"] = "Débogage : prompt envoyé à l'IA",
    ["AI Dictionary is up to date."] = "Dictionnaire AI est à jour.",
    ["An AI Dictionary update check is already in progress."] = "Une vérification des mises à jour de Dictionnaire AI est déjà en cours.",
    ["Could not check for updates while offline."] = "Impossible de vérifier les mises à jour hors ligne.",
    ["Could not check for AI Dictionary updates:\n%1"] = "Impossible de vérifier les mises à jour de Dictionnaire AI :\n%1",
    ["AI Dictionary %1 is available.\n\nInstalled version: %2\n\nUpdate now?"] = "Dictionnaire AI %1 est disponible.\n\nVersion installée : %2\n\nMettre à jour maintenant ?",
    ["Updating AI Dictionary..."] = "Mise à jour de Dictionnaire AI...",
    ["AI Dictionary update failed:\n%1"] = "Échec de la mise à jour de Dictionnaire AI :\n%1",
    ["AI Dictionary was updated.\n\nPlease quit and restart KOReader to load the new version."] = "Dictionnaire AI a été mis à jour.\n\nQuittez et relancez KOReader pour charger la nouvelle version.",
    ["Could not open settings:\n%1"] = "Impossible d'ouvrir les paramètres :\n%1",
    ["Request timeout"] = "Délai de requête",
    ["Request timeout: %1 s"] = "Délai de requête : %1 s",
    ["How long to wait for an AI reply before asking whether to keep waiting (%1–%2 seconds)."] = "Durée d'attente d'une réponse IA avant de demander si vous voulez continuer (%1–%2 secondes).",
    ["Please enter a whole number of seconds between %1 and %2."] = "Veuillez saisir un nombre entier de secondes entre %1 et %2.",
    ["Maximum predefined request timeout reached (%1 seconds).\nAutomatic cancellation in %2..."] = "Délai de requête maximum pré-défini atteint (%1 secondes).\nAnnulation automatique dans %2...",
    ["Wait another %1 seconds"] = "Attendre encore %1 secondes",
    ["Request cancelled after the maximum timeout (%1 seconds)."] = "Requête annulée après le délai maximum (%1 secondes).",
  },
}

local function normalize_lang(lang)
  if type(lang) ~= "string" or lang == "" or lang == "C" then
    return nil
  end
  lang = lang:match("^([^.:@]+)") or lang
  if lang:match("^en[_-]") or lang == "en" then
    return nil
  end
  return lang
end

local function language_candidates(lang)
  local candidates = { lang }
  local short = lang:lower():match("^(%a+)")
  if short and short ~= lang then
    candidates[#candidates + 1] = short
  end
  return candidates
end

local function current_ui_language()
  local lang = koreader_gettext.current_lang
  if (not lang or lang == "" or lang == "C")
      and G_reader_settings
      and type(G_reader_settings.readSetting) == "function" then
    local ok, value = pcall(G_reader_settings.readSetting, G_reader_settings, "language")
    if ok and type(value) == "string" then
      lang = value
    end
  end
  return lang
end

function GetText.gettext(msgid)
  if type(msgid) ~= "string" or msgid == "" then
    return msgid
  end

  local lang = normalize_lang(current_ui_language())
  if lang then
    for index, candidate in ipairs(language_candidates(lang)) do
      local catalog = translations[candidate]
      local translated = catalog and catalog[msgid]
      if translated then
        return translated
      end
    end
  end

  return koreader_gettext(msgid)
end

setmetatable(GetText, {
  __call = function(_, msgid)
    return GetText.gettext(msgid)
  end,
})

return GetText
