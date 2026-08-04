import Foundation
import MimicCLICore

// The executable is a thin shell so the whole command surface lives in a library that tests can
// import and drive directly.
exit(await MimicCommand.run())
