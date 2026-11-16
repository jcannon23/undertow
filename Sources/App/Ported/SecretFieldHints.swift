// Adapted from Ghostwriter (https://github.com/mshll/ghostwriter), GPL-3.0. Changed for Undertow, 2026-11.
import Foundation

enum SecretFieldHints {
    private static let passwordWords = [
        "password", "passcode", "passwort", "mot de passe", "contraseña", "senha", "wachtwoord", "пароль",
        "كلمة المرور", "كلمة السر", "パスワード", "密码", "密碼", "비밀번호",
    ]
    private static let credentialAutofillTypes: Set<String> = ["credentials", "strong password"]

    static func mentionsPassword(_ label: String) -> Bool {
        passwordWords.contains {
            label.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
    }

    static func isCredentialAutofill(_ autofillType: String?) -> Bool {
        autofillType.map(credentialAutofillTypes.contains) ?? false
    }

    static func isPaymentAutofill(_ autofillType: String?) -> Bool {
        autofillType == "credit card"
    }

    private static let paymentOrOneTimeCodePhrases: Set<String> = Set([
        "card number", "card num", "card no", "cc number", "cc num", "credit card", "debit card", "cc csc",
        "cvv", "cvv2", "cvc", "cvc2", "csc", "security code", "card verification", "cc exp", "card expiry",
        "card exp", "expiry date", "expiration date", "exp date", "mm yy", "mm yyyy",
        "one time code", "one time passcode", "one time password", "otp", "verification code",
        "authentication code", "2fa code",
        "رقم البطاقة", "بطاقة الائتمان", "رمز الأمان", "تاريخ الانتهاء", "رمز التحقق", "رمز لمرة واحدة",
        "numéro de carte", "carte bancaire", "carte de crédit", "cryptogramme", "date d expiration", "mm aa",
        "code de vérification", "code à usage unique",
        "kartennummer", "kreditkarte", "prüfnummer", "sicherheitscode", "ablaufdatum", "gültig bis", "mm jj",
        "bestätigungscode", "einmalcode",
        "número de tarjeta", "tarjeta de crédito", "código de seguridad", "fecha de vencimiento",
        "fecha de caducidad", "código de verificación",
    ].map { words($0).joined() })
    private static let longestPhraseWords = 4
    private static let cardNumberDigits = 13...19

    static func namesPaymentOrOneTimeCode(_ name: String) -> Bool {
        let words = words(name)
        if !words.isEmpty, words.allSatisfy({ $0.allSatisfy(\.isNumber) }),
           cardNumberDigits.contains(words.reduce(0) { $0 + $1.count }) {
            return true
        }
        for start in words.indices {
            var run = ""
            for word in words[start..<min(start + longestPhraseWords, words.count)] {
                run += word
                if paymentOrOneTimeCodePhrases.contains(run) { return true }
            }
        }
        return false
    }

    private static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousIsLowercase = false
        for character in text {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                previousIsLowercase = false
                continue
            }
            if previousIsLowercase, character.isUppercase {
                words.append(current)
                current = ""
            }
            current.append(character)
            previousIsLowercase = character.isLowercase
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
    }
}
