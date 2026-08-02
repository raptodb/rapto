//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of unit tests and semantic analysis.

comptime {
    _ = @import("Aof.zig");
    _ = @import("cli.zig");
    _ = @import("cli/Server.zig");
    _ = @import("frames.zig");
    _ = @import("glob.zig");
    _ = @import("main.zig");
    _ = @import("Memory.zig");
    _ = @import("object.zig");
    _ = @import("object/collection.zig");
    _ = @import("object/collection/List.zig");
    _ = @import("object/collection/Map.zig");
    _ = @import("object/scalar.zig");
    _ = @import("object/scalar/Decimal.zig");
    _ = @import("object/scalar/Flag.zig");
    _ = @import("object/scalar/Integer.zig");
    _ = @import("object/scalar/Point.zig");
    _ = @import("object/scalar/String.zig");
    _ = @import("object/scalar/Void.zig");
    _ = @import("object/tagged_ptr.zig");
    _ = @import("Pipeline.zig");
    _ = @import("Pipeline/Query.zig");
    _ = @import("Pipeline/Query/Flags.zig");
    _ = @import("reply.zig");
    _ = @import("state_machine.zig");
    _ = @import("zprof.zig");
}
