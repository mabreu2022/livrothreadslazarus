# Programação Concorrente e Paralela com Threads no Lazarus

Repositório oficial com todos os **8 projetos práticos completos e compiláveis** do livro **"Programação Concorrente e Paralela com Threads no Lazarus"**.

Todo o código foi escrito estritamente em **Object Pascal / Free Pascal (`{$mode objfpc}{$H+}`)** para **FPC 3.2.2+** e **Lazarus (LCL)**, sem dependências proprietárias do Delphi, com suporte multiplataforma (Windows, Linux e macOS via `{$IFDEF UNIX}cthreads,{$ENDIF}`) e validado contra vazamentos de memória com **HeapTrc (`-gh -gl`)**.

---

## Requisitos de Compilação

- **Free Pascal Compiler (FPC):** `3.2.2` ou superior
- **Lazarus IDE / LCL:** `3.x` ou `4.x` (validado em Lazarus 4.8 + FPC 3.2.2)
- **Plataformas:** Windows (Win32/Win64), Linux (GTK2/GTK3/Qt5/Qt6) e macOS (Cocoa)
- **Dependências extras apenas para execução do Capítulo 7:** biblioteca nativa `sqlite3` (`sqlite3.dll` no Windows / `libsqlite3-0` no Linux) e OpenSSL (`libssl`/`libcrypto`) para endpoints HTTPS com `fphttpclient` + `opensslsockets`.

---

## Mapa dos Projetos por Capítulo

| Capítulo | Pasta | Projeto (`.lpi`) | Conceitos Aplicados |
| :---: | :--- | :--- | :--- |
| **Cap. 1** | [`projetos/cap01_ui_freeze`](projetos/cap01_ui_freeze) | `Cap01UiFreeze.lpi` | Benchmark visual de *UI Freeze*, demonstração empírica da reentrância destrutiva de `Application.ProcessMessages` e desacoplamento com `TThread`. |
| **Cap. 2** | [`projetos/cap02_hash_scanner`](projetos/cap02_hash_scanner) | `Cap02HashScanner.lpi` | Calculador streaming de hashes **SHA-256** (FIPS 180-4 puro em Pascal), ciclo de vida `Create(True)` + `Start`, captura de `FatalException`, encerramento gracioso em `OnCloseQuery` e `HeapTrc`. |
| **Cap. 3** | [`projetos/cap03_log_monitor`](projetos/cap03_log_monitor) | `LogMonitor.lpi` | Monitor de logs em alta vazão comparando `TThread.Synchronize` (ingênuo/bloqueante) vs. `Application.QueueAsyncCall` com *throttling*, drenagem em lote via `TThreadList` e limpeza obrigatória `Application.RemoveAsyncCalls(Self)`. |
| **Cap. 4** | [`projetos/cap04_threadsafe_cache`](projetos/cap04_threadsafe_cache) | `ThreadSafeCache.lpi` | Cache em memória thread-safe com TTL usando `SysUtils.TMultiReadExclusiveWriteSynchronizer`, limpeza periódica sem *busy-waiting* (`TSimpleEvent`), estatísticas *lock-free* (`Interlocked*64`) e `TCountingSemaphore` portátil em FPC 3.2.2. |
| **Cap. 5** | [`projetos/cap05_cavaleiros_lab`](projetos/cap05_cavaleiros_lab) | `cap05_cavaleiros_lab.lpi` | Laboratório interativo ("Versão Quebrada" vs. "Versão Corrigida") para reproduzir e erradicar *Race Condition*, *Deadlock da LCL* (`WaitFor` ↔ `Synchronize`), *Livelock* e *False Sharing* (padding de 64 bytes). |
| **Cap. 6** | [`projetos/cap06_threadpool_pipeline`](projetos/cap06_threadpool_pipeline) | `cap06_threadpool_pipeline.lpi` | Motor paralelo de processamento de imagens (`TFPMemoryImage` thread-safe) com infraestrutura própria: `TCancellationTokenSource`, `generic TBoundedThreadQueue<T>` com *backpressure*, `TThreadPool` portátil e `TCountdownEvent`. |
| **Cap. 7** | [`projetos/cap07_rest_sqlite_sync`](projetos/cap07_rest_sqlite_sync) | `cap07_rest_sqlite_sync.lpi` | Sincronizador paralelo **HTTP/REST → SQLite WAL** usando `TFPHTTPClient` + `opensslsockets` + `fpjson`, semáforo limitador de concorrência, *rate limiter*, cancelamento real (`TFPHTTPClient.Terminate`), sessão **SQLdb** isolada por worker e snapshots DTO para `TListView` e `TBufDataset`/`TDBGrid`. |
| **Cap. 8** | [`projetos/cap08_stress_tests`](projetos/cap08_stress_tests) | `cap08_stress_tests.lpi` | Suíte automatizada **FPCUnit** (`consoletestrunner`) com barreira de largada simultânea (`TStartBarrier`), watchdog anti-deadlock (`TDeadlockWatchdog`), testes de contenção extrema e validação `HeapTrc` (`0 unfreed memory blocks`). |

---

## Como Compilar

### Pela IDE Lazarus
1. Abra o Lazarus IDE.
2. Acesse **Projeto → Abrir Projeto...** e selecione o arquivo `.lpi` do capítulo desejado.
3. Pressione **`F9`** (Executar) ou **`Ctrl+F9`** (Compilar).

### Pela Linha de Comando (`lazbuild`)

**Windows (PowerShell):**
```powershell
& "C:\lazarus\lazbuild.exe" -B projetos\cap01_ui_freeze\Cap01UiFreeze.lpi
& "C:\lazarus\lazbuild.exe" -B projetos\cap08_stress_tests\cap08_stress_tests.lpi
.\projetos\cap08_stress_tests\cap08_stress_tests.exe --all --format=plain
```

**Linux / macOS:**
```bash
lazbuild -B projetos/cap01_ui_freeze/Cap01UiFreeze.lpi
lazbuild -B projetos/cap08_stress_tests/cap08_stress_tests.lpi
./projetos/cap08_stress_tests/cap08_stress_tests --all --format=plain
```

### Compilando Todos os Projetos de Uma Só Vez (PowerShell)
```powershell
Get-ChildItem projetos -Recurse -Filter "*.lpi" | ForEach-Object {
  & "C:\lazarus\lazbuild.exe" -B $_.FullName
}
```
