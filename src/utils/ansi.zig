const String = @import("types.zig").String;
pub const Color = struct {
    pub const RESET = "\x1b[0m";

    pub const BLACK = "\x1b[30m";
    pub const RED = "\x1b[31m";
    pub const GREEN = "\x1b[32m";
    pub const YELLOW = "\x1b[33m";
    pub const BLUE = "\x1b[34m";
    pub const MAGENTA = "\x1b[35m";
    pub const CYAN = "\x1b[36m";
    pub const WHITE = "\x1b[37m";

    pub const BOLD_RED = "\x1b[1;31m";
    pub const BOLD_GREEN = "\x1b[1;32m";
    pub const BOLD_YELLOW = "\x1b[1;33m";
    pub const BOLD_BLUE = "\x1b[1;34m";
    pub const BOLD_MAGENTA = "\x1b[1;35m";
    pub const BOLD_CYAN = "\x1b[1;36m";
    pub const BOLD_WHITE = "\x1b[1;37m";

    // Dim colors
    pub const DIM = "\x1b[2m";
    pub const DIM_WHITE = "\x1b[2;37m";
};

pub fn success(text: String) String {
    return Color.BOLD_GREEN ++ text ++ Color.RESET;
}

pub fn error_(text: String) String {
    return Color.BOLD_RED ++ text ++ Color.RESET;
}

pub fn warning(text: String) String {
    return Color.BOLD_YELLOW ++ text ++ Color.RESET;
}

pub fn info(text: String) String {
    return Color.BOLD_CYAN ++ text ++ Color.RESET;
}

pub fn dim(text: String) String {
    return Color.DIM ++ text ++ Color.RESET;
}

pub fn header(text: String) String {
    return Color.BOLD_BLUE ++ text ++ Color.RESET;
}
