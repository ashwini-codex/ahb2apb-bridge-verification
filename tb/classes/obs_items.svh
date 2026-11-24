// =============================================================================
// Monitor observation items
//   ahb_beat : one AHB beat (address phase + completed data phase) seen on the bus
//   apb_txn  : one completed APB transfer seen on the bus
// =============================================================================
class ahb_beat;
  logic [31:0] addr;
  bit          write;
  logic [2:0]  size;
  logic [2:0]  burst;
  logic [3:0]  prot;
  htrans_e     trans;
  logic [31:0] wdata;
  logic [31:0] rdata;
  bit          resp;           // final HRESP (1 = ERROR)
  bit          err_first;      // saw the HRESP=1/HREADY=0 first ERROR cycle
  int unsigned waits;          // data-phase cycles with HREADY low
  bit          b2b;            // address phase accepted in the same cycle the previous data phase completed
  bit          after_busy;     // directly preceded by BUSY cycle(s)
  time         t_addr, t_done;

  function string convert2string();
    return $sformatf("AHB %s %s addr=0x%08h size=%0d burst=%0d %s=0x%08h resp=%s waits=%0d%s%s",
                     write ? "WR" : "RD", trans == NONSEQ ? "NSQ" : "SEQ", addr, size, burst,
                     write ? "wdata" : "rdata", write ? wdata : rdata, resp ? "ERROR" : "OKAY",
                     waits, b2b ? " b2b" : "", after_busy ? " after-busy" : "");
  endfunction
endclass

class apb_txn;
  logic [NUM_SLV-1:0] psel;
  int                 slv;          // index of the selected slave
  logic [31:0]        paddr;
  bit                 pwrite;
  logic [31:0]        pwdata;
  logic [31:0]        prdata;
  logic [3:0]         pstrb;
  logic [2:0]         pprot;
  bit                 pslverr;
  int unsigned        waits;        // ACCESS cycles with PREADY low
  bit                 no_setup;     // ACCESS seen without a preceding SETUP (protocol error)
  time                t_setup, t_done;

  function string convert2string();
    return $sformatf("APB S%0d %s paddr=0x%08h %s=0x%08h pstrb=%b pprot=%b waits=%0d%s",
                     slv, pwrite ? "WR" : "RD", paddr, pwrite ? "pwdata" : "prdata",
                     pwrite ? pwdata : prdata, pstrb, pprot, waits, pslverr ? " PSLVERR" : "");
  endfunction
endclass
