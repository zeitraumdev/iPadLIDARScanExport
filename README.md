# iPad LIDAR Scan OBJ Export

This project shows how to export an OBJ file of the 3D mesh created by an ARKit 3.5 Application with the iPad Pro (4th generation).

It is based on the [Visualising and Interacting with a Reconstructed Scene][1] sample by Apple and leverages the Model I/O framework to convert, assamble and export the mesh.

You can read more about it and our assessment of the iPad Pro LIDAR sensor on our [Medium.com][3] article.

## The magic happens in the [ViewControllers][2]:
``` swift
@IBAction func saveButtonPressed(_ sender: UIButton)
```
method and is not in any way, shape or form intended to be optimized or parallelized.
It's purpose is strictly educational :wink:

## What you need to run it:
* iOS 13.4+
* XCode 11.4+
* iOS device with LIDAR sensor (as of April 2020 just the iPad Pro)



[1]:https://developer.apple.com/documentation/arkit/world_tracking/visualizing_and_interacting_with_a_reconstructed_scene
[2]:iPadLIDARScanExport/ViewController.swift
[3]:https://medium.com/zeitraumgruppe/what-arkit-3-5-and-the-new-ipad-pro-bring-to-the-table-d4bf25e5dd87
