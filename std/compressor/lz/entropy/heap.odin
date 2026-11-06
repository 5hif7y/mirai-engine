package entropy

// The library's binary max-heap on `less`: same sift order, so ties pop in the same order.

heap_promote :: proc "contextless" (h:[]$T, i:int,
    less:proc "contextless" (a,b:T) -> bool) #no_bounds_check {
    i:=i
    for i>0 {
        parent:=(i-1)>>1
        if !less(h[parent],h[i]) {return}
        h[parent],h[i]=h[i],h[parent]
        i=parent
    }
}

// After reading h[0]: removes it (the hole walks down to a leaf, the last element fills it).
heap_popped :: proc "contextless" (h:[]$T,
    less:proc "contextless" (a,b:T) -> bool) #no_bounds_check {
    n:=len(h)
    i:=0
    for {
        child:=i*2+1
        if child>=n {break}
        if child+1<n && less(h[child],h[child+1]) {child+=1}
        h[i]=h[child]
        i=child
    }
    n-=1
    if i<n {
        h[i]=h[n]
        heap_promote(h,i,less)
    }
}

// After appending the new element at the end of h.
heap_push :: proc "contextless" (h:[]$T, less:proc "contextless" (a,b:T) -> bool) {
    if len(h)>0 {heap_promote(h,len(h)-1,less)}
}

heap_make :: proc "contextless" (h:[]$T, less:proc "contextless" (a,b:T) -> bool) #no_bounds_check {
    n:=len(h)
    for cur:=n>>1;cur>0; {
        cur-=1
        i:=cur
        for {
            child:=i*2+1
            if child>=n {break}
            if child+1<n && less(h[child],h[child+1]) {child+=1}
            if less(h[child],h[i]) {break}
            h[i],h[child]=h[child],h[i]
            i=child
        }
    }
}
