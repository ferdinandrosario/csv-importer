require 'spec_helper'

# High level integration specs
describe CSVImporter do
  # Mimics an active record model
  class User
    include Virtus.model
    include ActiveModel::Model

    attribute :email
    attribute :f_name
    attribute :l_name
    attribute :confirmed_at

    validates_presence_of :email
    validates_format_of :email, with: /[^@]+@[^@]/ # contains one @ symbol
    validates_presence_of :f_name

    def self.transaction
      yield
    end

    def persisted?
      @persisted ||= false
    end

    def save
      if valid?
        @persisted = true
      end
    end

    def self.find_by_email(email)
      store.find { |u| u.email == email }
    end

    def self.find_by_f_name(name)
      store.find { |u| u.f_name == name }
    end

    def self.find_by_l_name(name)
      store.find { |u| u.l_name == name }
    end

    def self.reset_store!
      @store = [
        User.new(email: "mark@example.com", f_name: "mark", l_name: "old last name", confirmed_at: Time.new(2012))
    ].tap { |u| u.map(&:save) }
    end

    def self.store
      @store ||= reset_store!
    end
  end

  class ImportUserCSV
    include CSVImporter

    model User

    column :email, required: true, as: /email/i, to: ->(email) { email.downcase }
    column :f_name, as: :first_name, required: true
    column :last_name,  to: :l_name
    column :confirmed,  to: ->(confirmed, model) do
      model.confirmed_at = confirmed == "true" ? Time.new(2012) : nil
    end

    identifier :email # will find_or_update via

    when_invalid :skip # or :abort
  end

  class ImportUserCSVByFirstName
    include CSVImporter

    model User

    column :email, required: true
    column :first_name, to: :f_name, required: true
    column :last_name,  to: :l_name
    column :confirmed,  to: ->(confirmed, model) do
      model.confirmed_at = confirmed == "true" ? Time.new(2012) : nil
    end

    identifier :f_name

    when_invalid :abort
  end

  before do
    User.reset_store!
  end

  describe "happy path" do
    it 'imports' do
      csv_content = "email,confirmed,first_name,last_name
BOB@example.com,true,bob,,"

      import = ImportUserCSV.new(content: csv_content)
      expect(import.rows.size).to eq(1)

      row = import.rows.first

      expect(row.csv_attributes).to eq(
        {
          "email" => "BOB@example.com",
          "first_name" => "bob",
          "last_name" => nil,
          "confirmed" => "true"
        }
      )

      import.run!

      expect(import.report.valid_rows.size).to eq(1)
      expect(import.report.created_rows.size).to eq(1)

      expect(import.report.message).to eq "Import completed: 1 created"

      model = import.report.valid_rows.first.model
      expect(model).to be_persisted
      expect(model).to have_attributes(
        "email" => "bob@example.com", # was downcased!
        "f_name" => "bob",
        "l_name" => nil,
        "confirmed_at" => Time.new(2012)
      )
    end
  end

  describe "invalid records" do
    it "does not import them" do
      csv_content = "email,confirmed,first_name,last_name
  NOT_AN_EMAIL,true,bob,,"
      import = ImportUserCSV.new(content: csv_content)
      import.run!

      expect(import.rows.first.model).to_not be_persisted

      expect(import.report.valid_rows.size).to eq(0)
      expect(import.report.created_rows.size).to eq(0)
      expect(import.report.invalid_rows.size).to eq(1)
      expect(import.report.failed_to_create_rows.size).to eq(1)

      expect(import.report.message).to eq "Import completed: 1 failed to create"
    end

    it "maps errors back to the csv header column name" do
      csv_content = "email,confirmed,first_name,last_name
  bob@example.com,true,,last,"
      import = ImportUserCSV.new(content: csv_content)
      import.run!

      row = import.report.invalid_rows.first
      expect(row.errors.size).to eq(1)
      expect(row.errors).to eq("first_name" => "can't be blank")
    end
  end

  describe "missing required columns" do
    let(:csv_content) do
"confirmed,first_name,last_name
bob@example.com,true,,last,"
    end

    let(:import) { ImportUserCSV.new(content: csv_content) }

    it "lists missing required columns" do
      expect(import.header.missing_required_columns).to eq(["email"])
    end

    it "is not a valid header" do
      expect(import.header).to_not be_valid
    end

    it "returns a report when you attempt to run the report" do
      import.valid_header?
      report = import.report

      expect(report).to_not be_success
      expect(report.status).to eq(:invalid_header)
      expect(report.missing_columns).to eq([:email])
      expect(report.message).to eq("The following columns are required: email")
    end
  end

  describe "missing columns" do
    it "lists missing columns" do
      csv_content = "email,first_name,
  bob@example.com,bob,"
      import = ImportUserCSV.new(content: csv_content)

      expect(import.header.missing_required_columns).to be_empty
      expect(import.header.missing_columns).to eq(["last_name", "confirmed"])
    end
  end

  describe "extra columns" do
    it "lists extra columns" do
      csv_content = "email,confirmed,first_name,last_name,age
  bob@example.com,true,,last,"
      import = ImportUserCSV.new(content: csv_content)

      expect(import.header.extra_columns).to eq(["age"])
    end
  end

  describe "find or create" do
    it "finds or create via identifier" do
      csv_content = "email,confirmed,first_name,last_name
bob@example.com,true,bob,,
mark@example.com,false,mark,new_last_name"
      import = ImportUserCSV.new(content: csv_content)

      import.run!

      expect(import.report.valid_rows.size).to eq(2)
      expect(import.report.created_rows.size).to eq(1)
      expect(import.report.updated_rows.size).to eq(1)

      model = import.report.created_rows.first.model
      expect(model).to be_persisted
      expect(model).to have_attributes(
        email: "bob@example.com",
        f_name: "bob",
        l_name: nil,
        confirmed_at: Time.new(2012)
      )

      model = import.report.updated_rows.first.model
      expect(model).to be_persisted
      expect(model).to have_attributes(
        email: "mark@example.com",
        f_name: "mark",
        l_name: "new_last_name",
        confirmed_at: nil
      )

      expect(import.report.message).to eq "Import completed: 1 created, 1 updated"
    end

    it "finds or create by identifier when the attributes does not match the column header" do
      csv_content = "email,confirmed,first_name,last_name
mark-new@example.com,false,mark,new_last_name"
      import = ImportUserCSVByFirstName.new(content: csv_content)

      import.run!

      expect(import.report.updated_rows.size).to eq(1)

      model = import.report.updated_rows.first.model
      expect(model).to be_valid
      expect(model).to have_attributes(
        email: "mark-new@example.com",
        f_name: "mark",
        l_name: "new_last_name",
        confirmed_at: nil
      )
    end

    it "applies transformation before running the find" do
      csv_content = "email,confirmed,first_name,last_name
MARK@EXAMPLE.COM,false,mark,new_last_name"

      import = ImportUserCSV.new(content: csv_content)

      import.run!

      expect(import.report.created_rows.size).to eq(0)
      expect(import.report.updated_rows.size).to eq(1)

      model = import.report.updated_rows.first.model
      expect(model).to be_valid
      expect(model).to have_attributes(
        email: "mark@example.com",
        f_name: "mark",
        l_name: "new_last_name",
        confirmed_at: nil
      )
    end

    it "handles errors just fine" do
      csv_content = "email,confirmed,first_name,last_name
mark@example.com,false,,new_last_name"
      import = ImportUserCSV.new(content: csv_content)

      import.run!

      expect(import.report.valid_rows.size).to eq(0)
      expect(import.report.created_rows.size).to eq(0)
      expect(import.report.updated_rows.size).to eq(0)
      expect(import.report.failed_to_create_rows.size).to eq(0)
      expect(import.report.failed_to_update_rows.size).to eq(1)
      expect(import.report.message).to eq "Import completed: 1 failed to update"

      model = import.report.failed_to_update_rows.first.model
      expect(model).to be_persisted
      expect(model).to have_attributes(
        email: "mark@example.com",
        f_name: nil,
        l_name: "new_last_name",
        confirmed_at: nil
      )
    end

  end

  it "strips cells" do
    csv_content = "email,confirmed,first_name,last_name
bob@example.com   ,  true,   bob   ,,"
    import = ImportUserCSV.new(content: csv_content)

    import.run!

    model = import.report.created_rows.first.model
    expect(model).to have_attributes(
      email: "bob@example.com",
      confirmed_at: Time.new(2012),
      f_name: "bob",
      l_name: nil
    )
  end

  it "strips and downcases columns" do
    csv_content = "Email,Confirmed,First name,last_name
bob@example.com   ,  true,   bob   ,,"
    import = ImportUserCSV.new(content: csv_content)

    expect { import.run! }.to_not raise_error
  end

  it "imports from a file (IOStream)" do
    csv_content = "Email,Confirmed,First name,last_name
bob@example.com   ,  true,   bob   ,,"
    csv_io = StringIO.new(csv_content)
    import = ImportUserCSV.new(file: csv_io)

    expect { import.run! }.to_not raise_error
  end

  it "imports from a path" do
    import = ImportUserCSV.new(path: "spec/fixtures/valid_csv.csv")

    expect { import.run! }.to_not raise_error
  end

  describe "#when_invalid" do
    it "could abort" do
      csv_content = "email,confirmed,first_name,last_name
bob@example.com,true,,
mark@example.com,false,mark," # missing first names

      import = ImportUserCSVByFirstName.new(content: csv_content)

      expect { import.run! }.to_not raise_error

      expect(import.report.valid_rows.size).to eq(0)
      expect(import.report.created_rows.size).to eq(0)
      expect(import.report.updated_rows.size).to eq(0)
      expect(import.report.failed_to_create_rows.size).to eq(1)
      expect(import.report.failed_to_update_rows.size).to eq(0)

      expect(import.report.message).to eq "Import aborted"
    end
  end

  describe "updating config on the fly" do
    it "works" do
      csv_content = "email,confirmed,first_name,last_name
new-mark@example.com,false,new mark,old last name"

      import = ImportUserCSV.new(
        content: csv_content,
        identifier: :l_name
      )

      report = import.run!

      expect(import.report.created_rows.size).to eq(0)
      expect(import.report.updated_rows.size).to eq(1)

    end
  end

  it "handles invalid csv files" do
    csv_content = %|email,confirmed,first_name,last_name,,
bob@example.com,"false"
bob@example.com,false,,in,,,"""|

    import = ImportUserCSV.new(
      content: csv_content,
      identifier: :l_name
    ).run!

    expect(import).to_not be_success
    expect(import.message).to eq "Unclosed quoted field on line 3."
  end

  it "column matching via regexp" do
    csv_content = %|Email Address,confirmed,first_name,last_name,,
bob@example.com,false,bob,,|

    import = ImportUserCSV.new(
      content: csv_content,
    ).run!

    expect(import).to be_success
    expect(import.message).to eq "Import completed: 1 created"
  end
end
