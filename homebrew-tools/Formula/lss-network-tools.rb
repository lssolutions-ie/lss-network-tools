class LssNetworkTools < Formula
  desc "Professional macOS network diagnostic toolkit"
  homepage "https://github.com/korshakov/lss-network-tools"
  url "https://github.com/korshakov/lss-network-tools/archive/refs/tags/v1.0.0.tar.gz"
  version "1.0.0"
  sha256 "7bc62513ccc3a9fec9c4ce79413f6fefc4eed4362584eb3d9781fc83a38ccac1"
  license "MIT"

  depends_on "nmap"
  depends_on "arp-scan"
  depends_on "speedtest-cli"

  def install
    bin.install "lss-network-tools-macos.sh" => "lss"
  end

  test do
    system "#{bin}/lss", "--version"
  end
end
