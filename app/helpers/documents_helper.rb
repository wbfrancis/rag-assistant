module DocumentsHelper
  TYPE_LABELS = {
    "application/pdf" => "PDF",
    "text/markdown" => "MD",
    "text/html" => "HTML",
    "text/plain" => "TXT"
  }.freeze

  def doc_type_label(document)
    TYPE_LABELS.fetch(document.content_type, document.content_type.to_s.split("/").last.upcase)
  end
end
