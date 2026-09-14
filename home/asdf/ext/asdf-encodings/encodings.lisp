#+xcvb (module (:depends-on ("pkgdcl")))

;;; http://www.iana.org/assignments/character-sets

(in-package :asdf-encodings)

(defparameter *encodings*
  ;; Define valid names for an encoding.
  ;; We prefer the main name in Wikipedia,
  ;; but use dashes whenever Wikipedia uses underscores.
  ;; We also accept some common aliases
  ;; We probably should grab an official list from the IANA or something,
  ;; and match it against encodings known to any and all Lisp implementation???
  '((:utf-8 :utf8 :u8) ; our preferred default, environment-independent.
    (:us-ascii :ascii :iso-646-us :ANSI_X3.4-1968) ; in practice the lowest common denominator
    (:iso-646 :|646|) ; even lower common denominator for old international encodings
    ;;; ISO/IEC 8859
    (:iso-8859-1 :iso8859-1 :latin1 :latin-1 :l1 ; direct mapping to first 256 unicode characters
     :iso_8859-1 :iso-ir-100 :csISOLatin1 :ibm819 :cp819 :windows-28591)
    (:iso-8859-2 :iso8859-2 :latin2 :latin-2) ; eastern european; not to be confused with dos-cp852
    (:iso-8859-3 :iso8859-3 :latin3 :latin-3) ; esperanto, maltese, (turkish)
    (:iso-8859-4 :iso8859-4 :latin4 :latin-4) ; prefer latin6, utf-8.
    (:iso-8859-5 :iso8859-5) ; cyrillic; prefer koi8-r, or utf-8
    (:iso-8859-6 :iso8859-6) ; arabic
    (:iso-8859-7 :iso8859-7 :ecma-118) ; greek
    (:iso-8859-8 :iso8859-8) ; hebrew
    (:iso-8859-9 :iso8859-9 :latin5 :latin-5) ; turkish
    (:iso-8859-10 :iso8859-10 :latin6 :latin-6) ; nordic languages
    (:iso-8859-11 :iso8859-11) ; almost same as TIS 620 which is preferred for thai
    ;;(:iso-8859-12 :iso8859-12) ; abandoned. Was meant for devanagari. Use
    (:iso-8859-13 :iso8859-13 :latin7 :latin-7) ; baltic rim
    (:iso-8859-14 :iso8859-14 :latin8 :latin-8) ; celtic
    (:iso-8859-15 :iso8859-15 :latin9 :latin-9) ; formerly also latin0. Tweak of latin1.
    (:iso-8859-16 :iso8859-16 :latin10 :latin-10) ; south-eastern european
    ;;; Windows code pages
    (:windows-1250 :windows-cp1250 :cp-1250 :cp1250 :ms-ee) ; eastern european
    (:windows-1251 :windows-cp1251 :cp-1251 :cp1251 :ms-cyrl) ; russian
    (:windows-1252 :windows-cp1252 :cp-1252 :cp1252 :ms-ansi :windows-latin1) ; superset of latin1
    (:windows-1253 :windows-cp1253 :cp-1253 :cp1253 :ms-greek) ; not quite iso-8859-7; prefer UTF-8
    (:windows-1254 :windows-cp1254 :cp-1254 :cp1254 :ms-turk) ; superset of iso-8859-9; prefer UTF-8
    (:windows-1255 :windows-cp1255 :cp-1255 :cp1255 :ms-hebr) ; mostly iso-8859-8; prefer UTF-8
    (:windows-1256 :windows-cp1256 :cp-1256 :cp1256 :ms-arab) ; incompatible w/ iso-8859-6; use UTF-8
    (:windows-1257 :windows-cp1257 :cp-1257 :cp1257 :ms-baltic :winbaltrim) ; prefer UTF-8
    (:windows-1258 :windows-cp1258 :cp-1258 :cp1258 :ms-viet) ; vietnamese combining. Prefer UTF-8.
    (:windows-cp932 :cp-932 :cp932 :windows-31j) ; Microsoft extension of Shift-JIS
    (:windows-cp936 :cp-936 :cp936) ; Simplified Chinese. Extends GB2312 with most of GBK. Use 54936.
    (:windows-cp949 :cp-949 :cp949) ; variant of EUC-KR. Use UTF-8
    (:windows-cp950 :cp-950 :cp950) ; Microsoft variant of Big5
    ;;; DOS code pages
    ;;; For some of these CLISP has both "ms" and "ibm" variants
    ;;; as in cp437 and cp437-ibm. We write CLISP!? next to them.
    (:dos-cp437 :cp-437 :cp437) ; Original IBM PC character set. CLISP!?
    (:dos-cp737 :cp-737 :cp737) ; Greek.
    (:dos-cp775 :cp-775 :cp775) ; Estonian, Lithuanian and Latvian
    (:dos-cp850 :cp-850 :cp850) ; Western Europe. Default MS-DOS code page in Windows 95.
    (:dos-cp852 :cp-852 :cp852) ; Central Europe. CLISP!?
    (:dos-cp855 :cp-855 :cp855) ; Russian. Not used much.
    (:dos-cp856 :cp-856 :cp856) ; Yet another russian code page.
    (:dos-cp857 :cp-857 :cp857) ; Turkish.
    (:dos-cp860 :cp-860 :cp860) ; Portuguese. CLISP!?
    (:dos-cp861 :cp-861 :cp861) ; Icelandic. CLISP!?
    (:dos-cp862 :cp-862 :cp862) ; Hebrew. CLISP!?
    (:dos-cp863 :cp-863 :cp863) ; French (mainly used in Quebec). CLISP!?
    (:dos-cp864 :cp-864 :cp864) ; Arabic. CLISP!?
    (:dos-cp865 :cp-865 :cp865) ; Nordic except Icelandic. CLISP!?
    (:dos-cp866 :cp-866 :cp866) ; Russian. Once popular.
    (:dos-cp869 :cp-869 :cp869 :dos-greek-2) ; failed before 737. CLISP!?
    (:dos-cp874 :cp-874 :cp874) ; Thai. Extension of TIS-620. CLISP!?
    (:cp-1133 :cp1133) ; IBM code page for lao
    ;;; Mac code pages
    (:mac-roman :macintosh :macos-roman) ; the latter name used by lispworks
    (:mac-arabic)
    (:mac-central-europe :mac-latin2) ; mac-latin2 name used by cmucl
    (:mac-croatian)
    (:mac-cyrillic :x-mac-cyrillic) ; sbcl calls it x-mac-cyrillic
    (:mac-greek)
    (:mac-hebrew)
    (:mac-icelandic :mac-iceland)
    (:mac-romania)
    (:mac-thai) ; extension of TIS-620.
    (:mac-turkish)
    (:mac-ukraine)
    (:mac-dingbat)
    (:mac-symbol)
    ;;; Implementation-specific hacks
    ;;(:beta-gk) ; CMUCL: ASCII encoding of ancient Greek
    ;;(:final-sigma) ; CMUCL: tweak final sigmas in greek (composable)
    ;;(:base64) ;; CLISP: base64-encoded latin1? composable?
    ;;(:cr :mac) (:crlf :dos) ; CMUCL: line ending tweaks (composable)
    ;; CJK character sets
    (:big5)
    (:big5-hkscs)
    (:euc-cn :euccn)
    (:euc-jp :eucjp)
    (:euc-kr :euckr)
    (:euc-tw :euctw)
    (:gbk) ; de facto standard of communist china, extends gb2312
    (:gb18030 :cp54936) ; official character set of communist china, extends gb2312 and gbk
    ;; ECMA-35 is same as ISO-2022, and free.
    (:iso-2022-jp) ; rfc 1468
    (:iso-2022-jp-1) ; rfc 2237
    (:iso-2022-jp-2) ; rfc 1554
    (:iso-2022-jp-3)
    (:iso-2022-jp-2004)
    (:iso-2022-kr) ; rfc 1557
    (:iso-2022-cn) (:iso-2022-cn-ext) ; both rfc-1922
    (:jis-x0201 :jisx0201 :jis_x0201) ; phonetic japanese katakana
    (:jis-x0208 :jisx0208 :jis_x0208)
    (:jis-x0212 :jisx0212 :jis_x0212)
    (:shift-jis :sjis)
    (:johab :ksc-5601 :ksc5601) ; korean
    ;;; Various National character sets
    (:armscii-8) ; armenian
    (:georgian-academy)
    (:georgian-ps)
    (:koi8-r :koi8r :cp-1866 :cp1866) ; russian
    (:koi8-u :koi8u :cp-21866 :cp21866) ; ukrainian
    (:tis-620) ; thai
    (:tcvn) ; viet
    (:viscii) ; viet
    ;;; Other computer-specific sets
    (:atascii :atarist) ; still supported by ECL
    (:hp-roman8) ; used on HP-UX
    ;;; EBCDIC
    (:cp-037 :cp037 :ibm037 :ibm-037 :ebcdic-us) ; latin1
    (:utf-ebcdic) ; utf-8
    ;;; Unicode encodings beside utf-8
    (:utf-7 :utf7) ; seldom used magic format for email
    (:cesu-8) ; kind of utf-8 encoded utf-16 (ugh). What oracle miscalls utf-8.
    (:java) ; java's modified UTF-8, like CESU-8 but with special encoding of U+0000.
    (:ucs-2 :ucs2) ; only BMP, may be either of the below
    (:ucs-2-le :ucs-2le :ucs2le)
    (:ucs-2-be :ucs-2be :ucs2be)
    (:utf-16 :utf16) ; may be either of the below
    (:utf-16-be :utf16be :utf16-be :utf-16be :unicode-16-big-endian) ;also unicode-16 in clisp
    (:utf-16-le :utf16le :utf16-le :utf-16le :unicode-16-little-endian)
    (:utf-32 :utf32 :ucs-4 :ucs4 :unicode-32) ; may be either of the below
    (:utf-32-be :utf32be :utf-32be :utf32-be :ucs-4-be :ucs-4be :unicode-32-big-endian)
    (:utf-32-le :utf32le :utf-32le :utf32-le :ucs-4-le :ucs-4le :unicode-32-little-endian)))

(defvar *normalized-encodings* (make-hash-table))

(defun find-implementation-encoding (encoding)
  (declare (ignorable encoding)) nil ;; default, for unsupported implementations
  (ignore-errors
   #+abcl (normalize-encoding encoding) ;; we bootstrap that in initialize-normalized-encodings
   #+allegro (excl:find-external-format encoding)
   #+(or clasp ecl) (ext:make-encoding encoding)
   #+clozure (ccl::normalize-external-format t encoding)
   #+clisp (find-symbol* encoding :charset nil)
   #+cmu (stream::ef-name (stream::find-external-format encoding))
   #+lispworks
   (or
    (case encoding
      ;; lispworks supports a :jis, but which encoding is it?
      ((:latin-1 :ascii :utf-8 :sjis :euc-jp :macos-roman) encoding)
      ((:ucs-2) :unicode)
      ((:ucs-2-le) '(:unicode :little-endian t))
      ((:ucs-2-be) '(:unicode :little-endian nil)))
    #+windows
    (let ((s (string encoding)))
      (and (< 3 (length s)) (string-equal "cp-" s :end2 3)
           (multiple-value-bind (i l)
               (parse-integer s :start 3 :junk-allowed t)
             (and i (= l (length s)) `(win32:code-page :id ,i))))))
   #+mkcl (si::make-encoding encoding)
   #+sbcl (and (sb-impl::get-external-format encoding) encoding)
   #+scl (and (or (lisp::encoding-character-width encoding) ; only works for fixed-width
                  (member encoding '(:utf-8 :utf-16 :utf-16le :utf-16be))) ; more may exist
              encoding)))

(defun initialize-normalized-encodings (&optional warn)
  #+abcl
  (loop :for name :in (let ((ae (find-symbol* :available-encodings :sys nil)))
                        (when ae (funcall ae)))
    :for n = (intern (string name) :keyword) ;; is this needed?
    :do (setf (gethash n *normalized-encodings*) name))
  ;; Special case for :default,
  ;; the meaning of which may vary depending on the environment.
  (setf (gethash :default *normalized-encodings*) :default)
  (loop :for names :in *encodings*
    :for (name encoding) = (loop :for n :in names
                             :for e = (find-implementation-encoding n)
                             :when e :return (list n e))
    :when name :do
    (loop :for n :in names
      :for e = (find-implementation-encoding n) :do
      (when (and e (not (eq e encoding)) warn)
        (warn "Encoding ~S differs from encoding for ~S yet registered as same" e encoding))
      (setf (gethash n *normalized-encodings*) name))))

(defun normalize-encoding (encoding)
  (values (gethash encoding *normalized-encodings*)))
