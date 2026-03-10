use std::collections::HashMap;

fn main() {
    let puzzle: [[i32; 9]; 9] = [[8,3,0,0,0,0,1,0,0], [0,0,0,0,0,2,3,0,0] , [1,0,0,0,5,0,0,0,4], [9,8,0,1,0,5,0,7,2], [2,5,7,9,0,0,0,3,1], [6,1,3,7,2,8,0,4,0], [4,2,0,5,0,1,0,0,3] ,[0,7,8,0,0,9,0,0,5] ,[0,6,0,4,0,0,0,0,0]];
    let mut possibleNumers: HashMap<(i16, i16), Vec<i16>>; // keys are coordinates | values are possible numbers array

    //fill possible numbers
    for row in puzzle.iter() {
        for &num in row.iter(){
            
        }
    }
}
