`define CPU_OLDEST_FUNCTION(NAME, N, LIMIT) \
  function automatic integer NAME(input logic [(N)-1:0] valid, \
      input logic [(N)*(RW+1)-1:0] ages); \
    localparam integer LEAVES=1<<$clog2(N), INDEX_BITS=((N)>1 ? $clog2(N):1); \
    logic [2*LEAVES-1:1] tree_valid; \
    logic [RW:0] tree_age [2*LEAVES-1:1]; \
    logic [INDEX_BITS-1:0] tree_index [2*LEAVES-1:1]; \
    logic left_wins; \
    begin \
      NAME=-1;left_wins=0; \
      if(|valid) begin \
        for(integer n=0;n<LEAVES;n=n+1) begin \
          tree_valid[LEAVES+n]=0;tree_age[LEAVES+n]=(RW+1)'(LIMIT);tree_index[LEAVES+n]=0; \
          if(n<(N)) begin \
            tree_valid[LEAVES+n]=valid[n] && ages[n*(RW+1)+:RW+1]<(RW+1)'(LIMIT); \
            tree_age[LEAVES+n]=tree_valid[LEAVES+n] ? ages[n*(RW+1)+:RW+1]:(RW+1)'(LIMIT); \
            tree_index[LEAVES+n]=INDEX_BITS'(n); \
          end \
        end \
        for(integer n=LEAVES-1;n>0;n=n-1) begin \
          left_wins=tree_valid[2*n] && (!tree_valid[2*n+1] || tree_age[2*n]<=tree_age[2*n+1]); \
          tree_valid[n]=tree_valid[2*n] || tree_valid[2*n+1]; \
          tree_age[n]=left_wins ? tree_age[2*n]:tree_age[2*n+1]; \
          tree_index[n]=left_wins ? tree_index[2*n]:tree_index[2*n+1]; \
        end \
        if(tree_valid[1]) NAME=int'(tree_index[1]); \
      end \
    end \
  endfunction
