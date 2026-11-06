package entropy

// The library's introsort (median-of-3 quicksort with a pivot area, heap sort past log1.5(n)
// levels). Ties end up in the same order as in the library, which the LRM dedupe depends on.
stdsort :: proc "contextless" (a:[]$T,less:proc "contextless" (x,y:T) -> bool) #no_bounds_check {
    swap :: #force_inline proc "contextless" (a:[]T,i,j:int) {a[i],a[j]=a[j],a[i]}
    // a<-c, b<-a, c<-b
    swap3 :: #force_inline proc "contextless" (a:[]T,i,j,k:int) {swap(a,i,j);swap(a,i,k)}
    Stk :: struct {left,right,len:int}
    length:=len(a)
    if length<=1 {return}
    left,right:=0,length-1
    stk:[64]Stk
    sp:=64
    {
        levs:=length
        for {
            sp-=1
            levs=(levs>>1)+(levs>>2)
            if levs==0 {break}
        }
        stk[sp-1].len=0
    }
    for length!=0 {
        inner: for length>1 {
            if length==2 {
                if less(a[right],a[left]) {swap(a,left,right)}
                break inner
            }
            mid:=left+(length>>1)
            if less(a[mid],a[left]) {
                if less(a[mid],a[right]) {
                    if less(a[left],a[right]) {swap(a,left,mid)} else {swap3(a,mid,left,right)}
                } else {
                    swap(a,left,right)
                }
            } else {
                if less(a[right],a[mid]) {
                    if less(a[left],a[right]) {swap(a,mid,right)} else {swap3(a,left,mid,right)}
                }
            }
            if length<=4 {
                if length==3 {break inner}
                p:=left+1
                if less(a[mid],a[p]) {
                    if less(a[p],a[right]) {swap(a,p,mid)} else {swap3(a,mid,p,right)}
                } else if less(a[p],a[left]) {
                    swap(a,left,p)
                }
                break inner
            }
            if sp==64 {
                // heap sort of [left,right]
                s:=length>>1
                i:=left+s
                ind,k:int
                build:=true
                for {
                    if build {
                        s-=1
                        i-=1
                        ind=i
                        k=(s<<1)+1
                    }
                    for {
                        v:=left+k
                        n:=v+1
                        if n<=right && less(a[v],a[n]) {k+=1;v=n}
                        if less(a[ind],a[v]) {
                            swap(a,ind,v)
                            ind=v
                            k=(k<<1)+1
                            if k<length {continue}
                        }
                        break
                    }
                    if s!=0 {build=true;continue}
                    length-=1
                    swap(a,left,right)
                    right-=1
                    ind=left
                    k=1
                    build=false
                    if length<=1 {break}
                }
                break inner
            }
            // quick sort
            piv:=left
            l,r:=left,right
            swap(a,mid,piv)
            for {
                for {
                    r-=1
                    if !less(a[piv],a[r]) {break}
                }
                if !(l<r) {break}
                for {
                    l+=1
                    if !less(a[l],a[piv]) {break}
                }
                if !(l<r) {l-=1;break}
                swap(a,l,r)
            }
            swap(a,piv,l)
            piv=l
            rpiv:=piv
            for {
                rpiv+=1
                if !(rpiv<right && !less(a[piv],a[rpiv])) {break}
            }
            lpiv:=piv
            for {
                lpiv-=1
                if !(left<lpiv) || less(a[lpiv],a[piv]) {break}
            }
            length=right-rpiv+1
            ll:=lpiv-left+1
            if length<ll {
                stk[sp]=Stk{rpiv,right,length}
                sp+=1
                right=lpiv
                length=ll
            } else {
                stk[sp]=Stk{left,lpiv,ll}
                sp+=1
                left=rpiv
            }
        }
        sp-=1
        left,right,length=stk[sp].left,stk[sp].right,stk[sp].len
    }
}
