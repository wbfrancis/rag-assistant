class DocumentsController < ApplicationController
  # Every query goes through Current.user.documents, so a user can never reach
  # another tenant's rows (a foreign id simply raises RecordNotFound -> 404).

  def index
    @documents = Current.user.documents.order(created_at: :desc)
  end

  def show
    @document = Current.user.documents.find(params[:id])
  end

  def new
    @document = Current.user.documents.new
  end

  def create
    @document = build_document

    if @document.save
      IngestDocumentJob.perform_later(@document.id)
      redirect_to @document, notice: "Uploaded. Ingesting…"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    Current.user.documents.find(params[:id]).destroy
    redirect_to documents_path, notice: "Deleted."
  end

  private

  def build_document
    file = params.dig(:document, :file)

    if file.present?
      raw = file.read.to_s.dup.force_encoding("UTF-8")
      Current.user.documents.new(
        title: params[:document][:title].presence || file.original_filename,
        source_uri: file.original_filename,
        content_type: detected_content_type(file),
        raw_text: raw,
        status: :pending
      )
    else
      Current.user.documents.new(
        title: params[:document][:title].presence || "Pasted document",
        source_uri: "paste",
        content_type: "text/markdown",
        raw_text: params[:document][:body].to_s,
        status: :pending
      )
    end
  end

  def detected_content_type(file)
    case File.extname(file.original_filename.to_s).downcase
    when ".md", ".markdown" then "text/markdown"
    when ".html", ".htm" then "text/html"
    else "text/plain"
    end
  end
end
