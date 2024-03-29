//+------------------------------------------------------------------+
//|                                                  Fann-Expert.mq4 |
//|                                                 Igor Kharchenko  |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Igor Kharchenko "
#property link      ""
#property version   "1.00"
#property strict


// Include Neural Network package
// Все функции писал в хедерах, потому что библиотеки компилироваться отказываются
// с ошибкой "is not 32-bit package".
// Я знаю, что это неправильно, но пока что пусть работает как есть.
#include <Fann2MQL.mqh>
#include <Fann/CsvIO.mqh>
#include <Fann/AnnFunctions.mqh>
#include <Fann/DebugFunctions.mqh>
#include <Fann/AnnCheckAnswerFunctions.mqh>


// Как именно будет тренироваться ИНС.
// 
// Enum:
//     TRAIN_UNTIL_MSE_REACHES_EPSILON - тренироваться до тех пор, пока MSE (среднеквадратическая ошибка) сети 
//                                       не будет меньше AnnEpsilon.
//     TRAIN_UNTIL_EPOCHS              - тренироваться заданное количество эпох.
enum TrainingMode
{
   TRAIN_UNTIL_MSE_REACHES_EPSILON = 1,
   TRAIN_UNTIL_EPOCHS = 2,
};


extern ENUM_TIMEFRAMES Timeframe = PERIOD_CURRENT;        // Таймфрейм
extern DataSource AnnDataSource = DATA_SOURCE_CLOSE;      // Источник входных данных: цены открытия/закрытия, SMA/EMA.
//
extern InitialCoefficients AnnInitialCoefficients = COEFF_MARIUSZ_WOLOSZYN; // Диапазон генерации начальных рандомных коэффициентов
//
extern int AmountOfInputNeurons = 10;                     // Количество входных нейронов
extern int AmountOfHiddenNeurons = 10;                    // Количество скрытых нейронов в первом скрытом слое
extern int AmountOfOutputNeurons = 3;                     // Количество выходных нейронов
//
extern bool SaveMSE = true;                               // Схоронять ли среднеквадратическую ошибку сети в файл
extern bool SaveNeuro = true;                             // Схоронять ли результат работы сети в файл
extern bool SaveNeuroRightAnswersStatistics = true;       // Схоронять ли статистику правильных ответов сети в файл
//
extern bool ShowNeuroRightAnswersStatistics  = true;      // Показывать ли статистику правильных ответов сети
//
extern int AmountOfTrainRates = 3000;                     // Количество баров, которое будет обработано сетью при тренировке
extern int AmountOfRunRates = 3000;                       // Количество баров, которое будет обработано сетью при запуске
int WindowSize = AmountOfInputNeurons;                    // Размер окна для обучения и работы ИНС
extern int AmountOfEpochs = 5;                            // Количество эпох, т.е. полных переборов тренировочных сетов
//
extern double AnnEpsilon = 0.0000001;                     // Ошибка ИНС
extern TrainingMode AnnTrainingMode = TRAIN_UNTIL_EPOCHS; // Сколько ИНС тренируется: пока есть эпохи/пока ошибка > AnnEps
//
extern bool ShowMSEWarnings = false;                      // Показывать ли сообщение о том, что MSE резко пошла вверх
//
extern bool LoadAnnFromFile = false;                      // Загружать ли пресет ИНС или создать чистую ИНС
extern string LoadPresetFileName = "";                    // Название файла загружаемого пресета сети (с указанием расширения файла)
extern bool SaveAnnToPreset = false;                      // Схоронять ли ИНС в пресет
extern string SavePresetFileName = "";                    // Название файла схороняемого пресета сети (с указанием расширения файла)

// todo: уточнить, можно ли впринципе попробовать новый алгоритм проверки
AnnAnswerCheckAlgorithm AnswerCheckAlgorithm = ALG_TREND_DIRECTION; // Алгоритм проверки ответа ИНС


int ann;                         // дескриптор нейронной сети
int mseFile;                     // дескриптор файла с MSE сети
int neuroCalculationResultsFile; // дескриптор файла с результатами работы сети
int neuroRightAnswersStatsFile;  // дескриптор файла со статистикой правильных ответов сети
int neuroCommonStatsFile;        // дескриптор файла с общей статистикой работы сети
int offset;                      // смещение относительно текущего графика
//
double rightAnswers;             // количество правильных ответов сети
int epochsPassed = 0;            // сколько эпох было пройдено
//
double input_vector[];           // вектор входных параметров ИНС.
double output_vector[];          // вектор выходных параметров ИНС.
//
bool mseFluctuation = false;     // mse (среднеквадр. ошибка) на какой-то итерации может внезапно пойти вверх: данный флаг проверяет, была ли зафиксирована флуктуация
int mseFluctuationsAmount = 0;   // подсчёт количества флуктуаций mse

int OnInit()
{
   if (!validate_input_parameters()) {
      debug(ERROR, "Переданные параметры невалидны.");
      return (INIT_PARAMETERS_INCORRECT);
   }
   
   if (true == LoadAnnFromFile) {
      string filename = get_ann_presets_path() + "\\" + LoadPresetFileName;
      ann = ann_load_from_file(filename);
      ann_reset_MSE(ann);
   } else {
      ann = ann_load(AnnInitialCoefficients);
   }
   
   if (-1 == ann) {
      debug(ERROR, "Не удалось инициализировать ИНС.");
      return (INIT_FAILED);
   }
   
   if (-1 == open_necessary_files()) {
      return (INIT_FAILED);
   }
   
   ArrayResize(input_vector, AmountOfInputNeurons);
   ArrayResize(output_vector, AmountOfOutputNeurons);
   
   MqlRates rates[];
   if (-1 == CopyRates(NULL, Timeframe, 0, AmountOfTrainRates + WindowSize + AmountOfOutputNeurons, rates)) {
      debug(ERROR, "Ошибка копирования исторических данных.");
      return (INIT_FAILED);
   }
   int ratesSize = ArraySize(rates);
   
   string message = "Скопировано " + IntegerToString(ratesSize) + " баров из исторических данных.";
   debug(WARNING, message);
   
   // Если запрошенное кол-во входных данных больше доступного, 
   // то устанавливаем максимально возможное количество.
   
   // todo поправить логику message-сообщения
   if (ratesSize < (AmountOfTrainRates + WindowSize + AmountOfOutputNeurons)) {
      message = "Вы запрашивали " + IntegerToString(AmountOfTrainRates) + " баров для тренировки сети, однако доступно " + IntegerToString(ratesSize) + ". ";
      message = message + "Будут использованы все доступные значения.";
      debug(WARNING, message);
      
      AmountOfTrainRates = ratesSize - WindowSize - AmountOfOutputNeurons;
   }
   if (ratesSize < (AmountOfRunRates + WindowSize + AmountOfOutputNeurons)) {
      message = "Вы запрашивали " + IntegerToString(AmountOfRunRates) + " баров для запуска сети, однако доступно " + IntegerToString(ratesSize) + ". ";
      message = message + "Будут использованы все доступные значения.";
      debug(WARNING, message);
      
      AmountOfRunRates = ratesSize - WindowSize - AmountOfOutputNeurons;
   }
   
   // Тренируем нейронную сеть и на каждом шаге вычисляем её ошибку.
   debug(INFORMATION, "Запускаем тренировку ИНС.");
   int train_result = train(ann, rates, mseFile);
   if (0 != train_result) {
      debug(ERROR, "Ошибка во время тренировки ИНС.");
      return INIT_FAILED;
   }
   
   // Запускаем ИНС на тех же данных и проверяем, как она себя поведёт.
   debug(INFORMATION, "Запускаем ИНС.");
   int run_result = run(ann, rates, neuroCalculationResultsFile, neuroRightAnswersStatsFile);
   if (0 != run_result) {
      debug(ERROR, "Ошибка во время работы ИНС на реальных данных.");
      return INIT_FAILED;
   }
   
   return INIT_SUCCEEDED;
}

// Закрываем файлы и схороняем всю статистику.
void OnDeinit(const int reason)
{
   close_csv_file(mseFile);
   close_csv_file(neuroCalculationResultsFile);
   close_csv_file(neuroRightAnswersStatsFile);
   
   save_statistics_to_csv_file(neuroCommonStatsFile);
   close_csv_file(neuroCommonStatsFile);
   
   string filename = get_ann_presets_path() + "\\" + SavePresetFileName;
   if (true == SaveAnnToPreset && -1 == ann_save_to_file(filename)) {
      debug(ERROR, "Ошибка при схоронении пресета ИНС.");
   }
   
   if (-1 == ann_destroy(ann)) {
      debug(ERROR, "Ошибка уничтожения экземпляра ИНС.");
   }
}

void OnTick()
{
   
   
}

// Возвращает путь к папке с пресетами ИНС.
// Returns:
//     string
// ======
string get_ann_presets_path()
{
   string path = __PATH__;
   string file = __FILE__;
   
   StringReplace(path, "\\" + __FILE__, "");
   StringReplace(path, "Experts", "Files\\Data\\NeuroPresets");
   
   return path;
}

// Схороняет статистику работы сети.
// 
// Parameters:
//     int file - дескриптор файла со статистикой работы сети.
// 
// Returns:
//     void
// ======
void save_statistics_to_csv_file(int file)
{
   string message[];
   ArrayResize(message, 2);
   
   message[0] = "Пройдено эпох";
   message[1] = DoubleToString(epochsPassed, 15);
   write_string_vector_to_csv_file(file, message);
   
   message[0] = "MSE в конце обучения";
   message[1] = DoubleToString(ann_get_MSE(ann), 15);
   write_string_vector_to_csv_file(file, message);
   
   message[0] = "MSE флуктуаций";
   message[1] = IntegerToString(mseFluctuationsAmount);
   write_string_vector_to_csv_file(file, message);

}

// Производит тренировку ИНС на исторических данных.
// Если алгоритм тренировки TRAIN_UNTIL_EPOCHS, то ИНС пройдёт по тренировочному сету заданное количество эпох (AnnEpochs).
// Если же алгоритм TRAIN_UNTIL_MSE_REACHES_EPSILON, то ИНС будет работать до тех пор, пока ошибка не станет меньше AnnEpsilon.
// 
// Parameters:
//     int _ann                - дескриптор ИНС.
//     MqlRates &rates[]       - исторические данные.
//     int _mseFile            - дескриптор файла, в который будут схороняться MSE (среднеквадратические ошибки) сети.
// 
// Returns:
//     int
//     0 если всё норм,
//     -1 если призошла ошибка.
// ======
int train(int _ann,
          MqlRates &rates[],
          int _mseFile
)
{
   double mse = 100500;
   int i;
   
   if (TRAIN_UNTIL_EPOCHS == AnnTrainingMode) {
      for (i = 0; i < AmountOfEpochs; i++) {
         int runResult = run_train_epoch(_ann, rates, _mseFile, i);
         if (0 != runResult) {
            return runResult;
         }
         
         epochsPassed++;
      }
   } else if (TRAIN_UNTIL_MSE_REACHES_EPSILON == AnnTrainingMode) {
      i = 0;
      while (mse > AnnEpsilon) {
         int runResult = run_train_epoch(_ann, rates, _mseFile, i);
         if (0 != runResult) {
            return runResult;
         }
         
         mse = ann_get_MSE(_ann);
         i++;
         
         epochsPassed++;
      }
   }
   
   return 0;
}

// См. описание функции train
int run_train_epoch(int _ann,
                    MqlRates &rates[],
                    int _mseFile,
                    int epochNumber
)
{
   double mse;
   int trainingSetResult;
   debug(INFORMATION, "Эпоха обучения " + IntegerToString(epochNumber + 1));
      
   trainingSetResult = pass_training_set(_ann, rates, _mseFile);
   if (-1 == trainingSetResult) {
      return -1;
   }
      
   mse = ann_get_MSE(_ann);
   if (-1 == mse) {
      return -1;
   }
   debug(INFORMATION, "Конец эпохи, MSE = " + DoubleToString(mse, 15));
   
   return 0;
}


// Перебирает весь тренировочный сет один раз.
//
// Parameters:
//     int _ann                - дескриптор ИНС.
//     MqlRates &rates[]       - исторические данные.
//     int _mseFile            - дескриптор файла, в который будут схороняться MSE (среднеквадратические ошибки) сети.
// 
// Returns:
//     int
//     0 если всё норм,
//     -1 если призошла ошибка.
// ======
int pass_training_set(int _ann,
                      MqlRates &rates[],
                      int _mseFile
)
{
   int i;
   string message;
   double mse = -1;
   double prevMse = -1;
   
   for (i = 0; i < AmountOfTrainRates; i++) {
      offset = i;
      if (0 == ArrayCopy(rates, input_vector, i, 0, WindowSize)) {
         debug(WARNING, "No items copied in input vector during ann train!");
      }
      ann_prepare_inputs(input_vector, rates);
      ann_prepare_outputs(output_vector, rates);
      
      if (-1 == ann_train(_ann, input_vector, output_vector)) {
         return -1;
      }
      
      mse = ann_get_MSE(_ann);
      if (-1 == mse) {
         return -1;
      }
      if (true == SaveMSE) {
         write_double_to_csv_file(_mseFile, mse);
      }
      // Первый шаг пропускаем, а на последующих смотрим, как поведёт себя ошибка:
      // по хорошему она должна идти постоянно вниз, но однажды она может внезапно изменить курс и пойти вверх.
      // Так что если следующее значение подскочило вверх, значит кидаем предупреждение, чтобы можно было сориентироваться.
      
      if (0 != i && mse > prevMse && false == mseFluctuation) {
         if (true == ShowMSEWarnings) {
            debug(INFORMATION, "Ошибка внезапно пошла вверх на " + IntegerToString(i + 1) + " шаге тренировочного сета.");
         }
         
         mseFluctuation = true;
         mseFluctuationsAmount++;
      }
      if (mse < prevMse) {
         mseFluctuation = false;
      }
      
      prevMse = mse;
      
      // На 100, 1000, 2000 и 2500 шаге показываем, какую MSE выдала ИНС.
      // (больше ~2к и ~2.5к баров терминал не выдаёт даже на малых таймфреймах)
      /*
      if (true == SaveNeuroStatistics && (100 == i || 1000 == i || 2000 == i || 2500 == i)) {
         message = "На " + IntegerToString(i) + " шаге обучения ИНС MSE = " + DoubleToString(mse, 15);
         debug(WARNING, message);
      }
      */
   }
   
   return 0;
}


// Запускает ИНС на тех же исторических данных.
// 
// Parameters:
//     int _ann                 - дескриптор ИНС.
//     MqlRates &rates[]        - исторические данные.
//     int _neuroResultsFile    - дескриптор файла, в который будут схороняться результаты работы сети.
//     int _neuroStatisticsFile - дескриптор файла, в который будет схороняться статистика работы сети.
// 
// Returns:
//     int
//     0 если всё норм,
//     -1 если призошла ошибка.
// ======
int run(int _ann,
        MqlRates &rates[],
        int _neuroResultsFile,
        int _neuroStatisticsFile
)
{
   string message;
   
   for (int i = 0; i < AmountOfRunRates; i++) {
      offset = i;
      if (0 == ArrayCopy(rates, input_vector, i, 0, WindowSize)) {
         message = "Значения не были скопированы из массива баров на шаге " + IntegerToString(i) + ".";
         debug(WARNING, message);
      }
      
      ann_prepare_inputs(input_vector, rates);
      
      for (int j = 0; j < AmountOfOutputNeurons; j++) {
         double out = ann_run(_ann, input_vector, j);
         if (FANN_DOUBLE_ERROR == out) {
            debug(ERROR, "Ошибка во время запуска ИНС.");
            return -1;
         }
         
         output_vector[j] = out;
      }
      
      double checkAnswer = check_answer_of_ann(output_vector, input_vector, AnswerCheckAlgorithm);
      rightAnswers = rightAnswers + checkAnswer;
      
      if (true == SaveNeuroRightAnswersStatistics) {
         write_double_to_csv_file(_neuroStatisticsFile, checkAnswer);
      }
      
      if (true == SaveNeuro) {
         // Угадываем только первое значение из трёх.
         write_double_to_csv_file(_neuroResultsFile, output_vector[0]);
      }
      
      // На 100, 1000, 2000 и 2500 шаге показываем, сколько ИНС выдала правильных ответов.
      // (больше ~2к и ~2.5к баров терминал не выдаёт даже на малых таймфреймах)
      
      // Опытным путём было выяснено, что до 100 шага точность вычисления становится чуть больше 50%,
      // поэтому проверим точность вычислений через каждый шаг.
      bool isNeedToWriteAnswer = i != 0 && i < 100;
      
      if (true == ShowNeuroRightAnswersStatistics && (isNeedToWriteAnswer || 100 == i || 1000 == i || 1500 == i || 2000 == i || 2500 == i)) {
         double right = (rightAnswers / (i + 1) ) * 100;
         message = "На " + IntegerToString(i + 1) + " шаге количество правильных ответов составило " + DoubleToString(right, 3) + "%.";
         debug(WARNING, message);
      }
   }
   
   if (true == ShowNeuroRightAnswersStatistics) {
      message = "Количество флуктуаций MSE = " + IntegerToString(mseFluctuationsAmount);
      debug(WARNING, message);
   }
   
   return 0;
}

// Валидирует входные параметры сети.
// 
// Returns:
//     bool
//     true в случае, если параметры валидны,
//     false в противном случае.
// ======
bool validate_input_parameters ()
{
   if (AmountOfInputNeurons <= 0) {
      debug(WARNING, "Количество входных нейронов сети не может быть <= 0.");
      return false;
   }
   if (AmountOfHiddenNeurons <= 0) {
      debug(WARNING, "Архитектура советника предполагает наличие скрытого слоя, так что кол-во нейронов в скрытом слое не может быть <= 0.");
      return false;
   }
   if (AmountOfOutputNeurons <= 0) {
      debug(WARNING, "Количество выходных нейронов сети не может быть <= 0.");
      return false;
   }
   if (AmountOfTrainRates <= 0) {
      debug(WARNING, "Количество баров, которое будет обработано сетью при тренировке, не может быть <= 0.");
      return false;
   }
   if (AmountOfRunRates <= 0) {
      debug(WARNING, "Количество баров, которое будет обработано сетью при запуске на реальных данных, не может быть <= 0.");
      return false;
   }
   if (AmountOfEpochs <= 0) {
      debug(WARNING, "Количество полных переборов тренировочных сетов ИНС не может быть <= 0.");
      return false;
   }
   if (AnnEpsilon <= 0) {
      debug(WARNING, "Значение AnnEpsilon не может быть <= 0.");
      return false;
   }
   if (WindowSize > AmountOfTrainRates || WindowSize > AmountOfRunRates) {
      debug(WARNING, "Размер окна не может быть больше количества баров, обработанных сетью при тренировке или запуске сети на реальных данных.");
      return false;
   }
   if (WindowSize != AmountOfInputNeurons) {
      string message = "Архитектура советника предполагает, что окно полностью будет задействовано во входном слое,";
      message = message + " поэтому размер окна должен совпадать с размером входного слоя сети.";
      debug(WARNING, message);
   }
   
   return true;
}

// Открывает нужные для работы файлы.
// 
// Returns:
//     int
//     0 в случае, если всё норм,
//     -1 в обратном случае.
// ======
int open_necessary_files()
{
   // Открываем файл с MSE.
   if (true == SaveMSE) {
      mseFile = open_csv_file("Data\\Neuro_MSE.csv", false);
      if (INVALID_HANDLE == mseFile) {
         debug(ERROR, "Не удалось открыть файл, в который нужно схоронять MSE сети.");
         return -1;
      }
   }
   // Открываем файл с результатами работы сети.
   if (true == SaveNeuro) {
      neuroCalculationResultsFile = open_csv_file("Data\\Neuro_Results.csv", false);
      if (INVALID_HANDLE == neuroCalculationResultsFile) {
         debug(ERROR, "Не удалось открыть файл, в который нужно схоронять результаты работы сети.");
         return -1;
      }
   }
   // Открываем файл со статистикой правильных ответов сети.
   if (true == SaveNeuroRightAnswersStatistics) {
      neuroRightAnswersStatsFile = open_csv_file("Data\\Neuro_RightAnswersStats.csv", false);
      if (INVALID_HANDLE == neuroRightAnswersStatsFile) {
         debug(ERROR, "Не удалось открыть файл, в который нужно схоронять статистику правильных ответов сети.");
         return -1;
      }
   }
   // В любом случае открываем файл с общей статистикой работы сети.
   neuroCommonStatsFile = open_csv_file("Data\\Neuro_CommonStats.csv", true);
   if (INVALID_HANDLE == neuroCommonStatsFile) {
      debug(ERROR, "Не удалось открыть файл, в который нужно схоронять общую статистику сети.");
      return -1;
   }
   
   return 0;
}