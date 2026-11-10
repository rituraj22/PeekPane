cask "peekpane" do
  version "1.1"
  sha256 "2679693a46c80c24c3c25cacad2c52c4260432bd4796bd871bd144c662b4b77d"

  url "https://github.com/rituraj22/PeekPane/releases/download/v#{version}/PeekPane-#{version}-macos.zip"
  name "PeekPane"
  desc "Float any cropped region of any Mac window in an always-on-top live PiP pane"
  homepage "https://github.com/rituraj22/PeekPane"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "PeekPane.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/PeekPane.app"],
                   sudo: false
    system_command "/usr/bin/tccutil",
                   args: ["reset", "ScreenCapture", "com.peekpane.app"],
                   sudo: false,
                   must_succeed: false
    system_command "/usr/bin/tccutil",
                   args: ["reset", "Accessibility", "com.peekpane.app"],
                   sudo: false,
                   must_succeed: false
  end

  zap trash: [
    "~/Library/Preferences/com.peekpane.app.plist",
    "~/Library/Saved Application State/com.peekpane.app.savedState",
  ]
end
