# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "Langfuse.discover_skills" do
  let(:logger) { instance_double(Logger, warn: nil) }
  let(:workspace) { Dir.mktmpdir("skill-discovery") }
  let(:root) { File.join(workspace, "skills") }

  around do |example|
    FileUtils.mkdir_p(root)
    Dir.chdir(workspace) { example.run }
  ensure
    FileUtils.remove_entry(workspace)
  end

  before { Langfuse.configuration.logger = logger }

  def install_skill(name)
    directory = File.join(root, name)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "SKILL.md"), "# Local skill")
    directory
  end

  def write_lock(directory, skills, lock_version: 1)
    File.write(File.join(directory, "langfuse-skills.lock"), { lockVersion: lock_version, skills: skills }.to_json)
  end

  it "finds sorted immediate directories without reading contents or making network calls" do
    install_skill("zebra")
    install_skill("alpha")
    install_skill(".hidden")
    install_skill("nested/child")
    File.write(File.join(root, "plain-file"), "not a directory")
    FileUtils.mkdir_p(File.join(root, "not-a-skill", "SKILL.md"))

    expect(Langfuse.discover_skills(dir: "skills")).to eq([{ name: "alpha" }, { name: "zebra" }])
    expect(a_request(:any, /.*/)).not_to have_been_made
  end

  it "follows directory and SKILL.md symlinks but skips broken ones" do
    target = install_skill("original")
    File.symlink(target, File.join(root, "alias"))
    FileUtils.mkdir_p(File.join(root, "linked-file"))
    File.symlink(File.join(target, "SKILL.md"), File.join(root, "linked-file", "SKILL.md"))
    File.symlink(File.join(root, "missing"), File.join(root, "broken"))

    expect(Langfuse.discover_skills(dir: root)).to eq(
      [{ name: "alias" }, { name: "linked-file" }, { name: "original" }]
    )
  end

  it "returns an empty list without warning for a missing directory" do
    expect(Langfuse.discover_skills(dir: File.join(root, "missing"))).to eq([])
    expect(logger).not_to have_received(:warn)
  end

  it "warns and returns an empty list for an unreadable directory" do
    allow(Dir).to receive(:children).with(root).and_raise(Errno::EACCES)

    expect(Langfuse.discover_skills(dir: root)).to eq([])
    expect(logger).to have_received(:warn).with(/Could not read skills directory/)
  end

  it "warns and returns an empty list when the root is a file" do
    file = File.join(root, "file")
    File.write(file, "contents")

    expect(Langfuse.discover_skills(dir: file)).to eq([])
    expect(logger).to have_received(:warn).with(/Could not read skills directory/)
  end

  it "skips uninspectable entries and continues discovery" do
    unreadable = install_skill("unreadable")
    install_skill("readable")
    allow(File).to receive(:stat).and_call_original
    allow(File).to receive(:stat).with(File.join(unreadable, "SKILL.md")).and_raise(Errno::EACCES)

    expect(Langfuse.discover_skills(dir: root)).to eq([{ name: "readable" }])
    expect(logger).to have_received(:warn).with(/could not inspect files/)
  end

  it "uses the root lock before the working directory lock and resolves paths from the lock" do
    install_skill("local")
    install_skill("unlocked")
    write_lock(workspace, [{ path: "skills/local", name: "cwd-name", version: 1 }])
    write_lock(root, [{ path: "./local", name: "locked-name", version: 7 }])

    expect(Langfuse.discover_skills(dir: root)).to eq([{ name: "locked-name", version: 7 }, { name: "unlocked" }])
  end

  it "uses the working directory lock when the root lock is absent" do
    directory = install_skill("local")
    write_lock(workspace, [{ path: directory, name: "locked-name", version: 2 }])

    expect(Langfuse.discover_skills(dir: root)).to eq([{ name: "locked-name", version: 2 }])
  end

  it "treats tildes in directory and lock paths as literal directory names" do
    install_skill("~helper")
    write_lock(root, [{ path: "~helper", name: "locked-name", version: 2 }])
    FileUtils.mv(root, File.join(workspace, "~skills"))

    expect(Langfuse.discover_skills(dir: "~skills")).to eq([{ name: "locked-name", version: 2 }])
  end

  ["{", "[]", '{"lockVersion":true,"skills":[]}', '{"lockVersion":1,"skills":{}}'].each do |contents|
    it "falls back to directory names for malformed lock #{contents.inspect}" do
      install_skill("local")
      write_lock(workspace, [{ path: "skills/local", name: "cwd-name", version: 1 }])
      File.write(File.join(root, "langfuse-skills.lock"), contents)

      expect(Langfuse.discover_skills(dir: root)).to eq([{ name: "local" }])
      expect(logger).to have_received(:warn).with(/Using directory names without versions/)
    end
  end

  it "falls back when the lock cannot be read" do
    install_skill("local")
    write_lock(root, [])
    allow(File).to receive(:read).with(File.join(root, "langfuse-skills.lock"), encoding: "UTF-8")
                                 .and_raise(Errno::EACCES)

    expect(Langfuse.discover_skills(dir: root)).to eq([{ name: "local" }])
    expect(logger).to have_received(:warn).with(/Using directory names without versions/)
  end

  it "falls back when the lock is a directory" do
    install_skill("local")
    FileUtils.mkdir_p(File.join(root, "langfuse-skills.lock"))

    expect(Langfuse.discover_skills(dir: root)).to eq([{ name: "local" }])
    expect(logger).to have_received(:warn).with(/Invalid skill lockfile/)
  end

  it "tolerates a lock removed after discovery" do
    install_skill("local")
    write_lock(root, [])
    allow(File).to receive(:stat).and_call_original
    lock = File.join(root, "langfuse-skills.lock")
    allow(File).to receive(:stat).with(lock).and_return(File.stat(lock), nil)

    expect(Langfuse.discover_skills(dir: root)).to eq([{ name: "local" }])
  end

  it "skips invalid lock records while retaining valid records and unknown fields" do
    install_skill("local")
    valid = { path: "local", name: "locked", version: 2, source: "ignored" }
    invalid = [nil, [], {}, valid.merge(path: ""), valid.merge(path: "bad\0path"),
               valid.merge(name: ""), valid.merge(name: "x" * 129),
               valid.merge(version: true), valid.merge(version: 1.5), valid.merge(version: 0),
               valid.merge(version: 2_147_483_648)]
    write_lock(root, [valid, *invalid])

    expect(Langfuse.discover_skills(dir: root)).to eq([{ name: "locked", version: 2 }])
    expect(logger).to have_received(:warn).with(/Skipping invalid skill entry/).exactly(invalid.size).times
  end

  it "keeps the last lock record for a path and first discovered duplicate name" do
    install_skill("alpha")
    install_skill("beta")
    write_lock(root, [{ path: "alpha", name: "old", version: 1 },
                      { path: "alpha", name: "shared", version: 2 },
                      { path: "beta", name: "shared", version: 3 }])

    expect(Langfuse.discover_skills(dir: root)).to eq([{ name: "shared", version: 2 }])
    expect(logger).to have_received(:warn).with(/Skipping duplicate skill name shared/)
  end

  it "accepts boundary names and versions and skips overly long directory names" do
    install_skill("x" * 129)
    install_skill("x" * 128)
    write_lock(root, [{ path: "x" * 128, name: "y" * 128, version: 2_147_483_647 }])

    expect(Langfuse.discover_skills(dir: root)).to eq([{ name: "y" * 128, version: 2_147_483_647 }])
    expect(logger).to have_received(:warn).with(/name exceeds 128 characters/)
  end
end
