unit uSha256;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TSHA256Digest = array[0..31] of Byte;

  TSHA256Context = record
    State: array[0..7] of LongWord;
    BitCount: QWord;
    Buffer: array[0..63] of Byte;
    BufLen: LongWord;
  end;

  TAbortCheckFunc = function: Boolean of object;

procedure SHA256Init(out Ctx: TSHA256Context);
procedure SHA256Update(var Ctx: TSHA256Context; const Data;
  Len: SizeInt);
procedure SHA256Final(var Ctx: TSHA256Context;
  out Digest: TSHA256Digest);
function SHA256DigestToHex(const Digest: TSHA256Digest): string;
function SHA256String(const S: RawByteString): string;
function SHA256SelfTest: Boolean;

function ComputeFileSHA256(const AFileName: string;
  AAbortCheck: TAbortCheckFunc;
  out ABytesRead: Int64;
  out ADigestHex: string): Boolean;

implementation

const
  K256: array[0..63] of LongWord = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5,
    $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3,
    $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc,
    $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7,
    $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13,
    $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3,
    $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5,
    $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208,
    $90befffa, $a4506ceb, $bef9a3f7, $c67178f2
  );

  IO_BUFFER_SIZE = 65536;

{$PUSH}
{$Q-}{$R-}

function RotR32(X: LongWord; N: Byte): LongWord; inline;
begin
  Result := (X shr N) or (X shl (32 - N));
end;

procedure SHA256Transform(var Ctx: TSHA256Context; const Block: PByte);
var
  W: array[0..63] of LongWord;
  A, B, C, D, E, F, G, H, S0, S1, Ch, Maj, T1, T2: LongWord;
  I: Integer;
begin
  for I := 0 to 15 do
    W[I] := (LongWord(Block[I * 4]) shl 24) or
            (LongWord(Block[I * 4 + 1]) shl 16) or
            (LongWord(Block[I * 4 + 2]) shl 8) or
            LongWord(Block[I * 4 + 3]);

  for I := 16 to 63 do
  begin
    S0 := RotR32(W[I - 15], 7) xor RotR32(W[I - 15], 18) xor
          (W[I - 15] shr 3);
    S1 := RotR32(W[I - 2], 17) xor RotR32(W[I - 2], 19) xor
          (W[I - 2] shr 10);
    W[I] := W[I - 16] + S0 + W[I - 7] + S1;
  end;

  A := Ctx.State[0];
  B := Ctx.State[1];
  C := Ctx.State[2];
  D := Ctx.State[3];
  E := Ctx.State[4];
  F := Ctx.State[5];
  G := Ctx.State[6];
  H := Ctx.State[7];

  for I := 0 to 63 do
  begin
    S1 := RotR32(E, 6) xor RotR32(E, 11) xor RotR32(E, 25);
    Ch := (E and F) xor ((not E) and G);
    T1 := H + S1 + Ch + K256[I] + W[I];
    S0 := RotR32(A, 2) xor RotR32(A, 13) xor RotR32(A, 22);
    Maj := (A and B) xor (A and C) xor (B and C);
    T2 := S0 + Maj;

    H := G;
    G := F;
    F := E;
    E := D + T1;
    D := C;
    C := B;
    B := A;
    A := T1 + T2;
  end;

  Inc(Ctx.State[0], A);
  Inc(Ctx.State[1], B);
  Inc(Ctx.State[2], C);
  Inc(Ctx.State[3], D);
  Inc(Ctx.State[4], E);
  Inc(Ctx.State[5], F);
  Inc(Ctx.State[6], G);
  Inc(Ctx.State[7], H);
end;

procedure SHA256Init(out Ctx: TSHA256Context);
begin
  Ctx.State[0] := $6a09e667;
  Ctx.State[1] := $bb67ae85;
  Ctx.State[2] := $3c6ef372;
  Ctx.State[3] := $a54ff53a;
  Ctx.State[4] := $510e527f;
  Ctx.State[5] := $9b05688c;
  Ctx.State[6] := $1f83d9ab;
  Ctx.State[7] := $5be0cd19;
  Ctx.BitCount := 0;
  Ctx.BufLen := 0;
  FillChar(Ctx.Buffer, SizeOf(Ctx.Buffer), 0);
end;

procedure SHA256Update(var Ctx: TSHA256Context; const Data;
  Len: SizeInt);
var
  P: PByte;
  ToCopy: SizeInt;
begin
  if Len <= 0 then
    Exit;

  P := @Data;
  Inc(Ctx.BitCount, QWord(Len) * 8);

  if Ctx.BufLen > 0 then
  begin
    ToCopy := 64 - SizeInt(Ctx.BufLen);
    if Len < ToCopy then
      ToCopy := Len;
    Move(P^, Ctx.Buffer[Ctx.BufLen], ToCopy);
    Inc(Ctx.BufLen, LongWord(ToCopy));
    Inc(P, ToCopy);
    Dec(Len, ToCopy);

    if Ctx.BufLen = 64 then
    begin
      SHA256Transform(Ctx, @Ctx.Buffer[0]);
      Ctx.BufLen := 0;
    end;
  end;

  while Len >= 64 do
  begin
    SHA256Transform(Ctx, P);
    Inc(P, 64);
    Dec(Len, 64);
  end;

  if Len > 0 then
  begin
    Move(P^, Ctx.Buffer[0], Len);
    Ctx.BufLen := LongWord(Len);
  end;
end;

procedure SHA256Final(var Ctx: TSHA256Context;
  out Digest: TSHA256Digest);
var
  I: Integer;
  Bits: QWord;
begin
  Bits := Ctx.BitCount;
  Ctx.Buffer[Ctx.BufLen] := $80;
  Inc(Ctx.BufLen);

  if Ctx.BufLen > 56 then
  begin
    if Ctx.BufLen < 64 then
      FillChar(Ctx.Buffer[Ctx.BufLen], 64 - Ctx.BufLen, 0);
    SHA256Transform(Ctx, @Ctx.Buffer[0]);
    Ctx.BufLen := 0;
  end;

  FillChar(Ctx.Buffer[Ctx.BufLen], 56 - Ctx.BufLen, 0);

  for I := 0 to 7 do
    Ctx.Buffer[56 + I] := Byte(Bits shr ((7 - I) * 8));

  SHA256Transform(Ctx, @Ctx.Buffer[0]);

  for I := 0 to 7 do
  begin
    Digest[I * 4]     := Byte(Ctx.State[I] shr 24);
    Digest[I * 4 + 1] := Byte(Ctx.State[I] shr 16);
    Digest[I * 4 + 2] := Byte(Ctx.State[I] shr 8);
    Digest[I * 4 + 3] := Byte(Ctx.State[I]);
  end;
end;

{$POP}

function SHA256DigestToHex(const Digest: TSHA256Digest): string;
const
  HexChars: array[0..15] of Char = '0123456789abcdef';
var
  I: Integer;
begin
  Result := '';
  SetLength(Result, 64);
  for I := 0 to 31 do
  begin
    Result[I * 2 + 1] := HexChars[Digest[I] shr 4];
    Result[I * 2 + 2] := HexChars[Digest[I] and $0F];
  end;
end;

function SHA256String(const S: RawByteString): string;
var
  Ctx: TSHA256Context;
  Digest: TSHA256Digest;
begin
  SHA256Init(Ctx);
  if Length(S) > 0 then
    SHA256Update(Ctx, S[1], Length(S));
  SHA256Final(Ctx, Digest);
  Result := SHA256DigestToHex(Digest);
end;

function SHA256SelfTest: Boolean;
const
  { Vetores oficiais NIST FIPS 180-4 }
  HASH_EMPTY =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
  HASH_ABC =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
begin
  Result := (SHA256String('') = HASH_EMPTY) and
            (SHA256String('abc') = HASH_ABC);
end;

function ComputeFileSHA256(const AFileName: string;
  AAbortCheck: TAbortCheckFunc;
  out ABytesRead: Int64;
  out ADigestHex: string): Boolean;
var
  FS: TFileStream;
  Ctx: TSHA256Context;
  Digest: TSHA256Digest;
  Buf: array of Byte;
  ReadNow: LongInt;
begin
  Result := False;
  ABytesRead := 0;
  ADigestHex := '';
  Buf := nil;

  FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Buf, IO_BUFFER_SIZE);
    SHA256Init(Ctx);

    repeat
      if Assigned(AAbortCheck) and AAbortCheck() then
        Exit(False);

      ReadNow := FS.Read(Buf[0], IO_BUFFER_SIZE);
      if ReadNow > 0 then
      begin
        SHA256Update(Ctx, Buf[0], ReadNow);
        Inc(ABytesRead, ReadNow);
      end;
    until ReadNow = 0;

    SHA256Final(Ctx, Digest);
    ADigestHex := SHA256DigestToHex(Digest);
    Result := True;
  finally
    FS.Free;
  end;
end;

end.
