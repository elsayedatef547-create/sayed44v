import SwiftUI
import CryptoKit

/// شاشة الدخول قبل فتح التطبيق. بتفضل مسجّل دخول على الجهاز لحد ما تعمل «تسجيل الخروج» من الإعدادات.
/// ملحوظة: ده قفل محلي بس (مفيش سيرفر)، بس الاسم والرقم السري مبقوش مكتوبين كنص صريح في التطبيق (بيتخزّنوا كبصمة SHA-256).
enum AppLogin {
    static let usernameHash = "aec1a3bf7793c59d2dfd6dd65bf48a5e4e5af9336e1a1bebd626ec9d3efa7ec2"
    static let passwordHash = "aec1a3bf7793c59d2dfd6dd65bf48a5e4e5af9336e1a1bebd626ec9d3efa7ec2"
    static let key = "app_logged_in"
    static let maxAttempts = 5
    static let lockSeconds: TimeInterval = 60

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(("oasis.login.v1:" + text).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct LoginView: View {
    @AppStorage(AppLogin.key) private var loggedIn = false
    @AppStorage(DemoMode.key) private var demoOn = false

    @State private var username = ""
    @State private var password = ""
    @State private var showError = false
    @State private var errorText = "اسم المستخدم أو الرقم السري غير صحيح"
    @State private var failures = 0
    @State private var lockedUntil: Date?
    @FocusState private var focused: Field?

    private enum Field { case username, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                    .padding(.top, 60)

                Text("OASIS")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.indigo)

                VStack(spacing: 12) {
                    TextField("اسم المستخدم", text: $username)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .focused($focused, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                    SecureField("الرقم السري", text: $password)
                        .textContentType(.password)
                        .focused($focused, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { signIn() }
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                    if showError {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        signIn()
                    } label: {
                        Text("دخول")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.indigo, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 6)

                    Button {
                        demoOn = true
                    } label: {
                        Label("جرّب التطبيق ببيانات وهمية", systemImage: "flask")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 28)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func signIn() {
        if let lockedUntil, Date() < lockedUntil {
            let remaining = Int(lockedUntil.timeIntervalSinceNow.rounded(.up))
            errorText = "محاولات كتير غلط. جرّب بعد \(remaining) ثانية."
            showError = true
            password = ""
            return
        }
        let user = username.normalizedDigits.trimmed
        let pass = password.normalizedDigits.trimmed
        if AppLogin.hash(user) == AppLogin.usernameHash && AppLogin.hash(pass) == AppLogin.passwordHash {
            showError = false
            failures = 0
            lockedUntil = nil
            loggedIn = true
        } else {
            failures += 1
            if failures >= AppLogin.maxAttempts {
                lockedUntil = Date().addingTimeInterval(AppLogin.lockSeconds)
                failures = 0
                errorText = "محاولات كتير غلط. جرّب بعد دقيقة."
            } else {
                errorText = "اسم المستخدم أو الرقم السري غير صحيح"
            }
            showError = true
            password = ""
        }
    }
}
