local DictionaryLabels = {}

local ENGLISH = { "Definition", "Example", "Synonyms", "Paraphrase", "Etymology" }

local BY_CODE = {
  en = ENGLISH,
  es = { "Definición", "Ejemplo", "Sinónimos", "Paráfrasis", "Etimología" },
  fr = { "Définition", "Exemple", "Synonymes", "Paraphrase", "Étymologie" },
  de = { "Definition", "Beispiel", "Synonyme", "Umschreibung", "Etymologie" },
  it = { "Definizione", "Esempio", "Sinonimi", "Parafrasi", "Etimologia" },
  pt = { "Definição", "Exemplo", "Sinónimos", "Paráfrase", "Etimologia" },
  ca = { "Definició", "Exemple", "Sinònims", "Parafrasi", "Etimologia" },
  nl = { "Definitie", "Voorbeeld", "Synoniemen", "Parafrase", "Etymologie" },
  pl = { "Definicja", "Przykład", "Synonimy", "Parafraza", "Etymologia" },
  ru = { "Определение", "Пример", "Синонимы", "Парафраз", "Этимология" },
  uk = { "Визначення", "Приклад", "Синоніми", "Парафраз", "Етимологія" },
  zh = { "释义", "例句", "同义词", "改写", "词源" },
  ja = { "定義", "例文", "類義語", "言い換え", "語源" },
  ko = { "정의", "예문", "유의어", "바꿔 말하기", "어원" },
  ar = { "التعريف", "مثال", "مرادفات", "إعادة صياغة", "أصل الكلمة" },
  tr = { "Tanım", "Örnek", "Eş anlamlılar", "Açıklama", "Etimoloji" },
  hu = { "Definíció", "Példa", "Szinonimák", "Parafrázis", "Etimológia" },
  id = { "Definisi", "Contoh", "Sinonim", "Parafrasa", "Etimologi" },
}

function DictionaryLabels.for_code(code)
  return BY_CODE[code] or ENGLISH
end

function DictionaryLabels.parse_list(code)
  local seen = {}
  local result = {}
  local function add(list)
    for index, label in ipairs(list) do
      if type(label) == "string" and label ~= "" and not seen[label] then
        seen[label] = true
        result[#result + 1] = label
      end
    end
  end
  add(DictionaryLabels.for_code(code))
  add(ENGLISH)
  return result
end

return DictionaryLabels
