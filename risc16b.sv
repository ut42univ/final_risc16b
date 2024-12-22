`default_nettype none

module risc16b (
    input wire clk,
    input wire rst,

    // 命令メモリインターフェース
    output logic [15:0] i_addr,
    output logic        i_oe,
    input  wire  [15:0] i_din,

    // データメモリインターフェース
    output logic [15:0] d_addr,
    output logic        d_oe,
    input  wire  [15:0] d_din,
    output logic [15:0] d_dout,
    output logic [ 1:0] d_we
);

  // ALU信号
  logic [15:0] alu_ain, alu_bin, alu_dout;
  logic [3:0] alu_op;

  // レジスタファイル信号
  logic [2:0] reg_file_rnum1, reg_file_rnum2, reg_file_wnum;
  logic [15:0] reg_file_dout1, reg_file_dout2, reg_file_din;
  logic        reg_file_we;

  // EXステージ信号
  logic [15:0] ex_result_reg;
  logic [15:0] ex_ir;
  logic [15:0] ex_result_in;
  logic ex_reg_file_we_in, ex_reg_file_we_reg;

  //============================================================================
  // モジュールインスタンス
  //============================================================================
  alu16 alu16_inst (
      .ain (alu_ain),
      .bin (alu_bin),
      .op  (alu_op),
      .dout(alu_dout)
  );

  reg_file reg_file_inst (
      .clk  (clk),
      .rst  (rst),
      .we   (reg_file_we),
      .rnum1(reg_file_rnum1),
      .rnum2(reg_file_rnum2),
      .wnum (reg_file_wnum),
      .dout1(reg_file_dout1),
      .dout2(reg_file_dout2),
      .din  (reg_file_din)
  );

  //============================================================================
  // IF (Instruction Fetch) ステージ
  //============================================================================
  logic [15:0] if_pc;  // PC
  logic [15:0] if_ir;  // Instruction Register
  logic [15:0] if_pc_bta;
  logic        if_pc_we;

  assign i_oe   = 1'b1;
  assign i_addr = if_pc;

  always_ff @(posedge clk) begin
    if (rst) if_pc <= 16'd0;
    else if_pc <= if_pc_we ? if_pc_bta : (if_pc + 16'd2);
  end

  always_ff @(posedge clk) begin
    if (rst) if_ir <= 16'd0;
    else if_ir <= i_din;
  end

  //============================================================================
  // ID (Instruction Decode) ステージ
  //============================================================================
  logic [15:0] id_operand_reg1, id_operand_reg2;
  logic [15:0] id_ir;
  logic [15:0] id_imm_reg;
  logic [15:0] id_pc;
  logic [15:0] id_operand_in1;
  logic [15:0] id_imm_in;

  assign reg_file_rnum1 = if_ir[10:8];
  assign reg_file_rnum2 = if_ir[7:5];

  // フォワーディングロジックの最適化
  always_comb begin
    id_operand_in1 = reg_file_dout1;
    if (ex_reg_file_we_in && (id_ir[10:8] == reg_file_rnum1)) begin
      id_operand_in1 = ex_result_in;
    end else if (ex_reg_file_we_reg && (ex_ir[10:8] == reg_file_rnum1)) begin
      id_operand_in1 = ex_result_reg;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) id_operand_reg1 <= 16'd0;
    else id_operand_reg1 <= id_operand_in1;
  end

  // フォワーディング(operand2)
  always_ff @(posedge clk) begin
    if (rst) id_operand_reg2 <= 16'd0;
    else if ((ex_reg_file_we_in == 1'b1) && (id_ir[10:8] == reg_file_rnum2))
      id_operand_reg2 <= ex_result_in;
    else if ((ex_reg_file_we_in == 1'b1) && (ex_ir[10:8] == reg_file_rnum2))
      id_operand_reg2 <= ex_result_reg;
    else id_operand_reg2 <= reg_file_dout2;
  end

  always_ff @(posedge clk) begin
    if (rst) id_ir <= 16'd0;
    else id_ir <= if_ir;
  end

  // 即値展開
  function [15:0] sign_extend_8(input [7:0] val);
    sign_extend_8 = {{8{val[7]}}, val};
  endfunction

  always_comb begin
    id_imm_in = (if_ir[15:11] == 5'b00100 || if_ir[15]) ?
        sign_extend_8(if_ir[7:0]) : {8'b0, if_ir[7:0]};
  end

  always_ff @(posedge clk) begin
    if (rst) id_imm_reg <= 16'd0;
    else id_imm_reg <= id_imm_in;
  end

  // 次ステージ用にPCを保持 (branchで使うため)
  always_ff @(posedge clk) begin
    if (rst) id_pc <= 16'd0;
    else id_pc <= if_pc;
  end

  // 分岐判定の最適化
  always_comb begin
    if_pc_we = 1'b0;
    unique case (if_ir[15:11])
      5'b10000: if_pc_we = (id_operand_in1 == '0);  // beqz
      5'b10001: if_pc_we = (id_operand_in1 != 16'd1);  // dec_bnez
      default:  ;
    endcase
  end

  assign if_pc_bta = if_pc + id_imm_in;

  //============================================================================
  // EX (Execution) ステージ
  //============================================================================
  assign alu_ain = (id_ir[15] == 1'b1) ? id_pc : id_operand_reg1;
  assign alu_bin = (id_ir[15:11] == 5'b00000) ? id_operand_reg2 : id_imm_reg;

  // データメモリ アドレス＆OE
  assign d_addr = id_operand_reg2;
  assign d_oe = (id_ir[15:11] == 5'b00000) && (id_ir[4:0] == 5'b10001 || id_ir[4:0] == 5'b10011 || id_ir[4:0] == 5'b10101);

  // データメモリ 書き込みデータ
  always_comb begin
    if (d_we == 2'b11) d_dout = id_operand_reg1;
    else if (d_we == 2'b01) d_dout = {id_operand_reg1[7:0], 8'b0};
    else if (d_we == 2'b10) d_dout = {8'b0, id_operand_reg1[7:0]};
    else d_dout = 16'b0;
  end

  // メモリアクセスロジックの最適化
  always_comb begin
    d_we = 2'b00;
    if (id_ir[15:11] == 5'b00000) begin
      unique case (id_ir[4:0])
        5'b10000: d_we = 2'b11;  // sw
        5'b10010: d_we = id_operand_reg2[0] ? 2'b10 : 2'b01;  // sbu
        default:  ;
      endcase
    end
  end

  // ALU演算種別
  always_comb begin
    if (id_ir[15] == 1'b1) alu_op = 4'b0100;
    else if (id_ir[15:11] == 5'b00000) alu_op = id_ir[3:0];
    else alu_op = id_ir[14:11];
  end

  // EX結果の最適化
  always_comb begin
    ex_result_in = alu_dout;  // デフォルト値

    if (id_ir[15:11] == 5'b10001) begin
      ex_result_in = id_operand_reg1 - 16'd1;  // dec_bnez
    end else if (id_ir[15:11] == 5'b00000) begin
      unique case (id_ir[4:0])
        5'b10001: ex_result_in = d_din;  // lw
        5'b10011: ex_result_in = {8'b0, id_operand_reg2[0] ? d_din[7:0] : d_din[15:8]};  // lbu
        5'b10101: ex_result_in = d_din + 16'd1;  // lw_inc
        default:  ;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (rst) ex_result_reg <= 16'd0;
    else ex_result_reg <= ex_result_in;
  end

  always_ff @(posedge clk) begin
    if (rst) ex_ir <= 16'd0;
    else ex_ir <= id_ir;
  end

  // レジスタファイル書き込み制御の最適化
  always_comb begin
    ex_reg_file_we_in = 1'b1;  // デフォルトで書き込み有効

    if (id_ir == 16'h0000 ||  // nop
        id_ir[15] && id_ir[15:11] != 5'b10001 ||  // 分岐命令（dec_bnez以外）
        d_we != 2'b00) begin  // ストア命令
      ex_reg_file_we_in = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) ex_reg_file_we_reg <= 1'b0;
    else ex_reg_file_we_reg <= ex_reg_file_we_in;
  end

  //============================================================================
  // WB (Write Back) ステージ
  //============================================================================
  assign reg_file_wnum = ex_ir[10:8];
  assign reg_file_din  = ex_result_reg;
  assign reg_file_we   = ex_reg_file_we_reg;

endmodule

//============================================================================
// レジスタファイル
//============================================================================
module reg_file (
    input  wire         clk,
    input  wire         rst,
    input  wire  [ 2:0] rnum1,
    input  wire  [ 2:0] rnum2,
    output logic [15:0] dout1,
    output logic [15:0] dout2,
    input  wire  [ 2:0] wnum,
    input  wire  [15:0] din,
    input  wire         we
);
  logic [15:0] registers[8];

  assign dout1 = registers[rnum1];
  assign dout2 = registers[rnum2];

  always_ff @(posedge clk) begin
    if (rst) registers <= '{default: 16'h0000};
    else if (we) registers[wnum] <= din;
  end
endmodule

//============================================================================
// ALU
//============================================================================
module alu16 (
    input  wire  [15:0] ain,
    input  wire  [15:0] bin,
    input  wire  [ 3:0] op,
    output logic [15:0] dout
);
  always_comb begin
    case (op)
      4'b0000: dout = ain;  // nop
      4'b0001: dout = bin;  // mov
      4'b0100: dout = ain + bin;  // add
      4'b0101: dout = ain - bin;  // sub
      4'b0110: dout = bin << 8;  // shift left 8
      4'b0111: dout = bin >> 8;  // shift right 8
      4'b1010: dout = ain & bin;  // and
      4'b1101: dout = ain >> 2;  // shift right 2 (original)
      4'b1110: dout = (bin & 16'h00FE) + 16'hC000;  // even lower 8 bits and add 0xC000 (original)
      4'b1111: dout = ((bin >> 8) & 16'h00FE) + 16'hC000;  // even upper 8 bits and add 0xC000 (original)
      default: dout = 16'b0;
    endcase
  end
endmodule

`default_nettype wire
