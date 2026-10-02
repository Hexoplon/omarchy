-- ZBar's camera preview, opened by the network panel's Wi-Fi QR scan, is a
-- short-lived dialog: center it over the desktop instead of tiling it.
o.window("^zbar$", {
  tag = "-default-opacity",
  float = true,
  center = true,
  opacity = "1 1",
})
