# Homebrew formula for the BarkVisor Device daemon (PAS-291).
# Runtime QEMU/swtpm/socket_vmnet/cdrtools come from Homebrew, not this keg.
# PAS-292: keg ships a signed helper + barkvisor-install-helper. brew services
# does not load that LaunchDaemon. NAT Workloads work without it.
class Barkvisor < Formula
  desc "Headless QEMU manager for a BarkVisor Device"
  homepage "https://github.com/pmdroid/barkvisor"
  license "MIT"
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
    system "swift", "build", "--disable-sandbox", "-c", "release",
           "--product", "BarkVisorHelper"
    binary = Dir["#{buildpath}/.build/**/release/BarkVisorApp"].find do |path|
      File.file?(path) && File.executable?(path)
    end
    odie "swift build did not produce BarkVisorApp" if binary.nil?
    helper = Dir["#{buildpath}/.build/**/release/BarkVisorHelper"].find do |path|
      File.file?(path) && File.executable?(path)
    end
    odie "swift build did not produce BarkVisorHelper" if helper.nil?

    bin.install binary => "barkvisor"
    libexec.install helper => "dev.barkvisor.helper"
    # Ad-hoc sign both keg binaries with stable identifiers. The helper
    # accepts this only for clients under the Homebrew prefix (PAS-292).
    # pkg/SMJobBless still requires the BarkVisor Team ID.
    system "codesign", "--force", "--sign", "-",
           "--identifier", "dev.barkvisor.app", bin/"barkvisor"
    system "codesign", "--force", "--sign", "-",
           "--identifier", "dev.barkvisor.helper", libexec/"dev.barkvisor.helper"
    system "codesign", "--verify", "--strict", bin/"barkvisor"
    system "codesign", "--verify", "--strict", libexec/"dev.barkvisor.helper"
    bin.install buildpath/"packaging/homebrew/barkvisor-install-helper"
    chmod 0755, bin/"barkvisor-install-helper"
    (share/"barkvisor/frontend").install "frontend/dist"
    # Same path as scripts/build-release.sh: share/barkvisor/templates.json.
    # Seeder reads Config.shareDir; brew services cwd is /var/lib/barkvisor.
    (share/"barkvisor").install "repos/templates.json"

    (pkgshare/"postinstall").write (buildpath/"packaging/homebrew/postinstall.sh").read
    chmod 0755, pkgshare/"postinstall"
    helper_plist = (buildpath/"packaging/homebrew/dev.barkvisor.helper.plist").read
    (pkgshare/"dev.barkvisor.helper.plist").write helper_plist

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
        Creating _barkvisor and /var/lib/barkvisor requires root.
        Run:
          sudo #{opt_pkgshare}/postinstall
          sudo brew services start barkvisor
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
      BarkVisor is a root LaunchDaemon running as _barkvisor.
      Data: /var/lib/barkvisor
      Sockets: /var/run/barkvisor

      Create the user and directories, then start the service:
        sudo #{opt_pkgshare}/postinstall
        sudo brew services start barkvisor

      NAT Workloads work without the privileged helper.
      Bridged networking copies the signed helper out of the keg:
        sudo #{opt_bin}/barkvisor-install-helper
    EOS
  end

  test do
    assert_path_exists bin/"barkvisor"
    assert_path_exists bin/"barkvisor-install-helper"
    assert_path_exists libexec/"dev.barkvisor.helper"
    assert_path_exists share/"barkvisor/templates.json"
    assert_path_exists share/"barkvisor/dev.barkvisor.helper.plist"
    plist = (prefix/"homebrew.mxcl.barkvisor.plist").read
    assert_match "AbandonProcessGroup", plist
    assert_match "_barkvisor", plist
    assert_match "BARKVISOR_DATA_DIR", plist
    assert_match "/var/lib/barkvisor", plist
    assert_match "BARKVISOR_SOCKET_DIR", plist
    assert_match "/var/run/barkvisor", plist
    refute_match "barkvisor.helper", plist
    helper_plist = (share/"barkvisor/dev.barkvisor.helper.plist").read
    assert_match "MachServices", helper_plist
    assert_match "/Library/PrivilegedHelperTools/dev.barkvisor.helper", helper_plist
  end
end
