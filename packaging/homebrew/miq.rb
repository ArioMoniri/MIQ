# Homebrew formula for the `miq` command-line tool (info / render / mosaic).
#
# This file is the source of truth; copy it to `Formula/miq.rb` in the tap
# (github.com/marcoduering/homebrew-miq) when releasing — see RELEASING.md,
# "CLI (Homebrew formula and universal binary)". The tap's `Casks/miq.rb`
# installs the app; this formula only builds the CLI, from the tagged source
# tarball, with no third-party dependencies.
#
# Because the tap also has a cask named `miq`, install the formula with
#   brew install --formula marcoduering/miq/miq
class Miq < Formula
  desc "Inspect and render NIfTI, MGH/MGZ, MRtrix MIF, NRRD and MetaImage volumes"
  homepage "https://miq.marco-duering.net"
  # Update both lines per release: `url` to the new tag, `sha256` to
  #   curl -fsSL <url> | shasum -a 256
  url "https://github.com/marcoduering/MIQ/archive/refs/tags/v1.6.2.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/marcoduering/MIQ.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma

  uses_from_macos "zlib"

  def install
    # SwiftPM's own sandbox can't nest inside Homebrew's build sandbox.
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "miq"
    bin.install ".build/release/miq"
  end

  test do
    assert_match "USAGE", shell_output("#{bin}/miq --help")
  end
end
