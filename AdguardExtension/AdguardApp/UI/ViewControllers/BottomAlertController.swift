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

class KeyboardMover {
    
    private weak var constraint: NSLayoutConstraint!
    private weak var view: UIView!
    private var initialValue: CGFloat!
    
    init(bottomConstraint: NSLayoutConstraint, view: UIView) {
        self.constraint = bottomConstraint
        self.view = view
        self.initialValue = bottomConstraint.constant
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardNotification(notification:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification,
                                               object: nil)
                
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillHide(notification:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }
    
    @objc
    func keyboardNotification(notification: NSNotification) {
            guard let userInfo = notification.userInfo else { return }
            guard let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                
            let keyboardHeight = keyboardFrame.height
            constraint.constant = keyboardHeight + initialValue
            
            UIView.animate(withDuration: 0.5,
                           animations: { self.view.layoutIfNeeded() },
                           completion: nil)
        }
        
    @objc
    func keyboardWillHide(notification: NSNotification) {
        constraint.constant = initialValue
        UIView.animate(withDuration: 0.5,
                       animations: { self.view.layoutIfNeeded() },
                       completion: nil)
    }
}

class BottomAlertController: UIViewController, UITextFieldDelegate {
    
    @IBOutlet weak var contentView: UIView!
    @IBOutlet weak var keyboardHeightLayoutConstraint: NSLayoutConstraint!
    
    private var keyboardMover: KeyboardMover!
    
    private var statusBarHeight: CGFloat {
        return UIApplication.shared.statusBarFrame.height
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        makeRoundCorners()

        keyboardMover = KeyboardMover(bottomConstraint: keyboardHeightLayoutConstraint, view: view)
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if touch.view != contentView {
            dismiss(animated: true, completion: nil)
        }
        else {
            super.touchesBegan(touches, with: event)
        }
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
    
    private func makeRoundCorners(){
        
        let corners: CACornerMask = [.layerMaxXMinYCorner, .layerMinXMinYCorner]
        let radius: CGFloat = 10.0
        
        if #available(iOS 11, *) {
            contentView.layer.cornerRadius = radius
            contentView.layer.maskedCorners = corners
        } else {
            var cornerMask = UIRectCorner()
            
            cornerMask.insert(.topLeft)
            cornerMask.insert(.topRight)
            
            let path = UIBezierPath(roundedRect: contentView.bounds, byRoundingCorners: cornerMask, cornerRadii: CGSize(width: radius, height: radius))
            let mask = CAShapeLayer()
            mask.path = path.cgPath
            contentView.layer.mask = mask
        }
        
        contentView.layer.cornerRadius = 10
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOffset = CGSize(width: 0, height: 0)
        contentView.layer.shadowRadius = 3
        contentView.layer.shadowOpacity = 1
    }
}
