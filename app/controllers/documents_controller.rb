class DocumentsController < ApplicationController
  before_action :prevent_demo_changes, only: %i[new create destroy]

  # Every query goes through Current.user.documents, so a user can never reach
  # another tenant's rows (a foreign id simply raises RecordNotFound -> 404).

  def index
    @documents = Current.user.documents.order(created_at: :desc)
  end

  def show
    @document = Current.user.documents.find(params[:id])
    @chunks = @document.chunks.order(:position)
    @active_chunk_id = params[:chunk_id].presence
    @sim = params[:sim].presence&.to_i
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
      document = Current.user.documents.new(
        title: params[:document][:title].presence || file.original_filename,
        source_uri: file.original_filename,
        content_type: detected_content_type(file),
        status: :pending
      )
      # Store the upload in Active Storage; the job extracts text from it later.
      document.file.attach(file)
      document
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
    when ".pdf" then "application/pdf"
    when ".md", ".markdown" then "text/markdown"
    when ".html", ".htm" then "text/html"
    else "text/plain"
    end
  end

  def prevent_demo_changes
    return unless demo_session?

    redirect_to documents_path, alert: "The public demo uses a fixed document collection." and return
  end
end
