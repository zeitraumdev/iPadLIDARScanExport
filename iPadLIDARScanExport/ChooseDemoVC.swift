//
//  ChooseDemoVC.swift
//  iPadLIDARScanExport
//
//  Created by Chinh Tran on 9/22/20.
//  Copyright © 2020 Apple. All rights reserved.
//

import UIKit
import ARKit
class ChooseDemoVC: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
    }
    
    @IBAction func lidarClicked(_ sender: Any) {
        guard ARWorldTrackingConfiguration.isSupported else {
                fatalError("""
                    ARKit is not available on this device. For apps that require ARKit
                    for core functionality, use the `arkit` key in the key in the
                    `UIRequiredDeviceCapabilities` section of the Info.plist to prevent
                    the app from installing. (If the app can't be installed, this error
                    can't be triggered in a production scenario.)
                    In apps where AR is an additive feature, use `isSupported` to
                    determine whether to show UI for launching AR experiences.
                """) // For details, see https://developer.apple.com/documentation/arkit
            }
        
            guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
                fatalError("""
                    Scene reconstruction requires a device with a LiDAR Scanner, such as the 4th-Gen iPad Pro.
                """)
            }
    }
    
    @IBAction func trueDepthClicked(_ sender: Any) {
    }
}
