package main

import "fmt"

func main() {
	sum := 0
	i := 0
	for i < 20000000 {
		sum += i
		i += 1
	}
	fmt.Println(sum)
}
