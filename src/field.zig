//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of fields API.

pub const Types = @import("field/types.zig").Types;
pub const ScalarItem = @import("field/scalar.zig").ScalarItem;

pub const Void = @import("field/scalar.zig").Void;
pub const Integer = @import("field/scalar.zig").Integer;
pub const Decimal = @import("field/scalar.zig").Decimal;
pub const Flag = @import("field/scalar.zig").Flag;
pub const String = @import("field/scalar.zig").String;
pub const Point = @import("field/scalar.zig").Point;

pub const List = @import("field/collection.zig").List;
pub const Map = @import("field/collection.zig").Map;

pub const splitSerialized = @import("field/types.zig").splitSerialized;
