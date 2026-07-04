package main

import "core:fmt"
import "game"

main :: proc() {
    const sz: usize = size_of(game.Save_Data)
    fmt.println("Save_Data size:", sz)
}
