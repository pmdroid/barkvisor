# Homebrew formula for the BarkVisor Device daemon (PAS-291).
# Runtime QEMU/swtpm/socket_vmnet/cdrtools come from Homebrew, not this keg.
# The privileged helper LaunchDaemon is PAS-292, not this formula.
class Barkvisor < Formula
  desc "Headless QEMU manager for a BarkVisor Device"
  homepage "https://barkvisor.dev"
  license "MIT"
  # GitHub releases currently ship pkg/standalone archives, not a Homebrew keg
  # layout. Prefer a prebuilt keg tarball when CI publishes one; until then
  # install from head (source: Xcode + bun).
  head "https://github.com/pmdroid/barkvisor.git", branch: "main"

  depends_on :macos
  depends_on arch: :arm64
  depends_on xcode: :build
  depends_on "bun" => :build
  depends_on "qemu"
  depends_on "swtpm"
  depends_on "socket_vmnet"
  depends_on "cdrtools"

  def install
    cd "frontend" do
      system "bun", "install", "--frozen-lockfile"
      system "bun", "run", "build"
    end
    frontend_index = buildpath/"frontend/dist/index.html"
    unless frontend_index.exist?
      odie "frontend/dist/index.html is required for the installed layout"
    end

    system "swift", "build", "--disable-sandbox", "-c", "release",
           "--product", "BarkVisorApp"
    binary = Dir["#{buildpath}/.build/**/release/BarkVisorApp"].find do |path|
      File.file?(path) && File.executable?(path)
    end
    odie "swift build did not produce BarkVisorApp" if binary.nil?

    bin.install binary => "barkvisor"
    bin.install_symlink "barkvisor" => "barkvisor-agent"
    (share/"barkvisor/frontend").install "frontend/dist"
    # Same path as scripts/build-release.sh: share/barkvisor/templates.json.
    # Seeder reads Config.shareDir; brew services cwd is /var/lib/barkvisor.
    (share/"barkvisor").install "repos/templates.json"
    # Reserved for the privileged helper (PAS-292). Empty until that formula.
    (libexec/"barkvisor").mkpath

    (pkgshare/"postinstall").write (buildpath/"packaging/homebrew/postinstall.sh").read
    chmod 0755, pkgshare/"postinstall"

    plist = (buildpath/"packaging/homebrew/homebrew.mxcl.barkvisor.plist").read
    plist = plist.gsub("@PROGRAM@", (opt_bin/"barkvisor").to_s)
    plist = plist.gsub("@HOMEBREW_PREFIX@", HOMEBREW_PREFIX.to_s)
    (prefix/"homebrew.mxcl.barkvisor.plist").write plist
  end

  def post_install
    script = pkgshare/"postinstall"
    if Process.euid.zero?
      system "/bin/bash", script
    else
      opoo <<~EOS
        Creating /var/lib/barkvisor requires root.
        Run:
          sudo #{opt_pkgshare}/postinstall
          sudo brew services start barkvisor
        Do not run brew install as root against a user Homebrew prefix.
      EOS
    end
  end

  # Homebrew's service DSL cannot set AbandonProcessGroup (PAS-223).
  # Do not set `run` here: brew services would regenerate the plist and drop
  # that key. The keg ships homebrew.mxcl.barkvisor.plist instead.
  service do
    name macos: "homebrew.mxcl.barkvisor"
    require_root true
  end

  def caveats
    <<~EOS
      BarkVisor is a root LaunchDaemon.
      Data: /var/lib/barkvisor
      Sockets: /var/run/barkvisor
      UI: http://localhost:7777
      Do not run brew install as root against a user Homebrew prefix.

      This formula currently builds from source (head). Prebuilt GitHub
      release artifacts use the pkg/standalone layout, not this keg; when a
      matching keg archive exists, the formula will prefer it. Source build
      needs Xcode and bun.

      Create the user and directories, then start the service:
        sudo #{opt_pkgshare}/postinstall
        sudo brew services start barkvisor
        sudo brew services restart barkvisor
        sudo brew services stop barkvisor
        brew services info barkvisor

      Bridged networking still needs the privileged helper (not this formula).
      NAT Workloads work without it.
    EOS
  end

  test do
    assert_path_exists bin/"barkvisor"
    assert_path_exists bin/"barkvisor-agent"
    assert_path_exists share/"barkvisor/templates.json"
    assert_path_exists libexec/"barkvisor"
    plist = (prefix/"homebrew.mxcl.barkvisor.plist").read
    assert_match "AbandonProcessGroup", plist
    refute_match "_barkvisor", plist
    refute_match "UserName", plist
    assert_match "BARKVISOR_DATA_DIR", plist
    assert_match "/var/lib/barkvisor", plist
    assert_match "BARKVISOR_SOCKET_DIR", plist
    assert_match "/var/run/barkvisor", plist
    refute_match "barkvisor.helper", plist
  end
end
