/**
       This file is part of Adguard for iOS (https://github.com/AdguardTeam/AdguardForiOS).
       Copyright © Adguard Software Limited. All rights reserved.
 
       Adguard for iOS is free software: you can redistribute it and/or modify
       it under the terms of the GNU General Public License as published by
       the Free Software Foundation, either version 3 of the License, or
       (at your option) any later version.
 
       Adguard for iOS is distributed in the hope that it will be useful,
       but WITHOUT ANY WARRANTY; without even the implied warranty of
       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
       GNU General Public License for more details.
 
       You should have received a copy of the GNU General Public License
       along with Adguard for iOS.  If not, see <http://www.gnu.org/licenses/>.
 */

import Foundation


class NewDnsServerController: BottomAlertController {
    
    var provider: DnsProviderInfo?
    
    // MARK: - IB Outlets
    
    @IBOutlet var themableLabels: [ThemableLabel]!
    
    @IBOutlet weak var addButton: RoundRectButton!
    @IBOutlet weak var cancelButton: RoundRectButton!
    @IBOutlet weak var deleteButton: RoundRectButton!
    @IBOutlet weak var saveButton: RoundRectButton!
    
    @IBOutlet weak var nameField: UITextField!
    @IBOutlet weak var upstreamsField: UITextField!
    
    @IBOutlet weak var dnsSeparator: UIView!
    
    @IBOutlet var separators: [UIView]!
    @IBOutlet weak var scrollContentView: UIView!
    
    // MARK: - services
    
    let theme: ThemeServiceProtocol = ServiceLocator.shared.getService()!
    
    let vpnManager: APVPNManager = ServiceLocator.shared.getService()!
    
    // MARK: - view controller lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name( ConfigurationService.themeChangeNotification), object: nil, queue: OperationQueue.main) {[weak self] (notification) in
            self?.updateTheme()
        }
        
        if provider != nil {
            nameField.text = provider?.name
            upstreamsField.text = provider?.servers?.first?.upstreams.first ?? ""
        }
        
        nameField.becomeFirstResponder()
        updateSaveButton()
        updateTheme()
    }
    
    // MARK: - Actions
    
    @IBAction func addAction(_ sender: Any) {
        vpnManager.addRemoteDnsServer(nameField.text ?? "", upstreams: [upstreamsField.text ?? ""])
        
        dismiss(animated: true, completion: nil)
    }
    
    @IBAction func cancelAction(_ sender: Any) {
        
        dismiss(animated: true, completion: nil)
    }
    
    @IBAction func deleteAction(_ sender: Any) {
        if provider == nil { return }
        vpnManager.deleteCustomDnsProvider(provider!)
        dismiss(animated: true, completion: nil)
    }
    
    @IBAction func saveAction(_ sender: Any) {
        if provider == nil || provider?.servers?.first == nil { return }
        provider!.name = nameField.text ?? ""
        provider!.servers?.first!.upstreams = [upstreamsField.text ?? ""]
        provider!.servers?.first!.name = provider!.name
        vpnManager.resetCustomDnsProvider(provider!)
        dismiss(animated: true, completion: nil)
    }
    
    // MARK: - textfield delegate methods
    
    @IBAction func editingChanged(_ sender: Any) {
        updateSaveButton()
    }
    
    // MARK: - private methods
    
    private func updateTheme() {
        scrollContentView.backgroundColor = theme.popupBackgroundColor
        theme.setupPopupLabels(themableLabels)
        theme.setupTextField(nameField)
        theme.setupTextField(upstreamsField)
        
        for separator in separators {
            separator.backgroundColor = theme.separatorColor
        }
    }
    
    private func updateSaveButton() {
        let dnsName = nameField.text ?? ""
        let dnsUrl = upstreamsField.text ?? ""
        let correctDns = dnsUrl.checkIfValidDnsServer()
        let enabled = dnsName.count > 0 && correctDns
        
        if !correctDns {
            dnsSeparator.backgroundColor = UIColor(hexString: "#df3812")
        } else {
            dnsSeparator.backgroundColor = UIColor.lightGray
        }
        
        addButton?.isEnabled = enabled
        saveButton?.isEnabled = enabled
    }
}
