package org.unisonweb.benchmark

import org.unisonweb._
import compilation2._
import Term.Term
import org.unisonweb.ABT.Name
import org.unisonweb.compilation2.Value.Lambda
import org.unisonweb.util.{Stream, Unboxed}

object Compilation2Benchmarks {

  import QuickProfile.{profile, suite}

  def N(n: Int): Int = math.random.ceil.toInt * n

  val stackB = new Array[B](1024)
  val stackU = new Array[U](1024)
  val r = Result()
  val top = new StackPtr(-1)

  def runTerm(t: Term): Value.Lambda =
    run(compileTop(Lib2.builtins)(t)).asInstanceOf[Value.Lambda]

  val triangleCount = 100000

  def main(args: Array[String]): Unit = {
    suite(
      profile("scala-triangle") {
        def triangle(n: Int, acc: Int): Int =
          if (n == 0) acc else triangle(n - 1, acc + n)
        triangle(N(triangleCount), N(0))
      },
      { val s = scala.Stream.range(0, N(triangleCount))
        profile("scala-stream-triangle") { s.foldLeft(N(0))(_ + _).toLong }
      },
      {
        val p = runTerm(Terms.triangle)
        profile("unison-triangle") {
          evalLam(p, r, top, stackU, N(triangleCount), N(0), stackB, null, null).toLong
        }
      },
      {
        profile("stream-triangle") {
          util.Stream.from(N(0)).take(N(triangleCount)).sumInt
        }
      },
      {
        profile("stream-triangle-fold-left-int-import") {
          Stream.from(N(0)).take(N(triangleCount))
            .foldLeft(0, null: Unboxed.Unboxed[Int])(Unboxed.F2.II_I_import(_ + _))((u, _) => u).toLong
        }
      },
      {
        profile("stream-triangle-fold-left-int-manually-inline") {
          Stream.from(N(0)).take(N(triangleCount))
            .foldLeft(0, null: Unboxed.Unboxed[Int])(Unboxed.F2.II_I_manually_inline(_ + _))((u, _) => u).toLong
        }
      },
      {
        profile("stream-triangle-fold-left-int-val") {
          Stream.from(N(0)).take(N(triangleCount))
            .foldLeft(0, null: Unboxed.Unboxed[Int])(Unboxed.F2.II_I_val(_ + _))((u, _) => u).toLong
        }
      },
      {
        profile("stream-triangle-fold-left-long") {
          Stream.from(N(0).toLong).take(N(triangleCount))
            .foldLeft(0, null: Unboxed.Unboxed[Long])(Unboxed.F2.LL_L(_ + _))((u, _) => u).toLong
        }
      },
      {
        val plusU = UnisonToScala.toUnboxed2 {
          Lib2.builtins(Name("+")) match { case Return(lam: Lambda) => lam }
        }

        val env = (new Array[U](20), new Array[B](20), new StackPtr(0), Result())
        profile("stream-triangle-unisonfold") {
          Stream.from(0).take(N(triangleCount))
            .asInstanceOf[Stream[Param]]
            .foldLeft(U0, null:Param)(plusU(env))((u,_) => u).toLong
        }
      }
    )
//    suite(
//      profile("scala-fib") {
//        def fib(n: Int): Int =
//          if (n < 2) n else fib(n - 1) + fib(n - 2)
//        fib(N(21))
//      },
//      {
//        val p = runTerm(Terms.fib)
//        profile("unison-fib") {
//          evalLam(p, r, top, stackU, U0, N(21), stackB, null, null).toLong
//        }
//      }
//    )
//    suite(
//      profile("scala-fibPrime") {
//        def fibPrime(n: Int): Int =
//          if (n < 2) n else fibPrime2(n - 1) + fibPrime2(n - 2)
//        def fibPrime2(n: Int): Int =
//          if (n < 2) n else fibPrime(n - 1) + fibPrime(n - 2)
//        fibPrime(N(21))
//      },
//      {
//        val p = runTerm(Terms.fibPrime)
//        profile("unison-fibPrime") {
//          evalLam(p, r, top, stackU, U0, N(21), stackB, null, null).toLong
//        }
//      }
//    )
  }
}
