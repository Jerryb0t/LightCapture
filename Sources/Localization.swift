import Foundation

/// Fixed resource keys and positional arguments; never look up interpolated text.
enum Localization {static var bundle:Bundle = .main}

func L(_ key:String,_ arguments:CVarArg...)->String {
    let format=Localization.bundle.localizedString(forKey:key,value:key,table:"Localizable")
    return arguments.isEmpty ? format : String(format:format,locale:Locale.current,arguments:arguments)
}
